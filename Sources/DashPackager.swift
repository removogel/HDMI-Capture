import Foundation

/// MPEG-DASH-Live-Stream: CMAF-Segmente (fMP4) mit einstellbarer Länge D, je ein Adaptation Set für Bild
/// und Ton, adressiert über `SegmentTemplate` mit `$Number$`. Segment n beginnt bei Medienzeit n · D.
/// Läuft komplett auf der Stream-Queue.
final class DashPackager {
    enum Track { case video, audio }

    let settings: StreamSettings
    /// Wie viele Segmente vorgehalten werden (gut 40 s)
    let keepSegments: Int
    private let videoTrackID = 1
    private let audioTrackID = 2

    private(set) var videoInit: [UInt8]?
    private(set) var audioInit: [UInt8]?
    private var videoSegments: [Int: [UInt8]] = [:]
    private var audioSegments: [Int: [UInt8]] = [:]
    private var latestVideo = -1
    private var latestAudio = -1
    /// Uhrzeit, zu der die Medienzeit 0 war
    private var availabilityStart: Date?
    private var videoParameters: VideoParameters?
    private var audioParameters: AudioParameters?

    private var pendingFrame: EncodedVideoFrame?
    private var videoSamples: [MP4.Sample] = []
    private var videoNumber = 0
    private var videoStartTicks: Int64 = 0

    private var audioSamples: [MP4.Sample] = []
    private var audioNumber = 0
    private var audioStartTicks: Int64 = 0

    init(settings: StreamSettings) {
        self.settings = settings
        keepSegments = Int((40 / settings.segmentDuration).rounded(.up))
    }

    /// Manifest vollständig (Bild und Ton bekannt)
    var isComplete: Bool { videoInit != nil && audioInit != nil }

    func latest(_ track: Track) -> Int { track == .video ? latestVideo : latestAudio }

    func segment(_ track: Track, _ number: Int) -> [UInt8]? {
        track == .video ? videoSegments[number] : audioSegments[number]
    }

    /// „video_12.m4s“ → (.video, 12)
    static func parseSegmentName(_ name: String) -> (track: Track, number: Int)? {
        guard name.hasSuffix(".m4s") else { return nil }
        let stem = name.dropLast(4)
        let parts = stem.split(separator: "_")
        guard parts.count == 2, let number = Int(parts[1]), number >= 0 else { return nil }
        switch parts[0] {
        case "video": return (.video, number)
        case "audio": return (.audio, number)
        default: return nil
        }
    }

    private static func ticks(_ time: Double, _ timescale: Int) -> Int64 {
        Int64((time * Double(timescale)).rounded())
    }

    // MARK: Video

    func addVideo(_ frame: EncodedVideoFrame, parameters: VideoParameters) {
        if parameters != videoParameters {
            // Erster Start oder neue Auflösung: Video-Segmente neu beginnen
            videoParameters = parameters
            videoInit = MP4.videoInit(parameters, trackID: videoTrackID)
            videoSegments.removeAll()
            latestVideo = -1
            videoSamples.removeAll()
            pendingFrame = nil
        }
        guard pendingFrame != nil || frame.isKeyframe else { return }   // mit einem Keyframe beginnen
        if availabilityStart == nil {
            availabilityStart = Date(timeIntervalSinceNow: -frame.time)
        }

        let ticks = Self.ticks(frame.time, 90_000)
        if let previous = pendingFrame {
            // Dauer eines Bildes = Abstand zum nächsten; nach Signalausfall Nennwert
            var duration = ticks - Self.ticks(previous.time, 90_000)
            if duration <= 0 || duration > 45_000 { duration = Int64(90_000 / StreamSettings.frameRate) }
            videoSamples.append(MP4.Sample(data: Self.lengthPrefixed(previous),
                                           duration: UInt32(duration),
                                           flags: previous.isKeyframe ? MP4.syncSampleFlags : MP4.nonSyncSampleFlags))
        }
        if frame.isKeyframe {
            // Neues Segment am ersten Keyframe ab der Segmentgrenze (der Encoder setzt ihn genau dort)
            let number = settings.segmentNumber(at: frame.time)
            if videoSamples.isEmpty {
                videoNumber = number
                videoStartTicks = ticks
            } else if number > videoNumber {
                finishVideoSegment()
                videoNumber = number
                videoStartTicks = ticks
            }
        }
        pendingFrame = frame
    }

    private func finishVideoSegment() {
        let number = videoNumber
        videoSegments[number] = MP4.mediaSegment(sequence: number + 1, trackID: videoTrackID,
                                                 baseTime: UInt64(max(videoStartTicks, 0)), samples: videoSamples)
        latestVideo = number
        videoSamples.removeAll()
        videoSegments = videoSegments.filter { $0.key > number - keepSegments }
    }

    private static func lengthPrefixed(_ frame: EncodedVideoFrame) -> [UInt8] {
        var out: [UInt8] = []
        for nal in frame.slices {
            out.appendU32(UInt32(nal.count))
            out += nal
        }
        return out
    }

    // MARK: Audio

    func addAudio(_ frame: EncodedAudioFrame, parameters: AudioParameters) {
        guard availabilityStart != nil else { return }   // Ton erst, wenn das Bild läuft
        if parameters != audioParameters {
            audioParameters = parameters
            audioInit = MP4.audioInit(parameters, trackID: audioTrackID, bitRate: StreamSettings.audioBitRate)
            audioSegments.removeAll()
            latestAudio = -1
            audioSamples.removeAll()
        }
        let number = settings.segmentNumber(at: frame.time)
        if audioSamples.isEmpty == false && number > audioNumber {
            finishAudioSegment()
        }
        if audioSamples.isEmpty {
            audioNumber = number
            audioStartTicks = Self.ticks(frame.time, parameters.sampleRate)
        }
        audioSamples.append(MP4.Sample(data: frame.data, duration: 1024, flags: MP4.syncSampleFlags))
    }

    private func finishAudioSegment() {
        let number = audioNumber
        audioSegments[number] = MP4.mediaSegment(sequence: number + 1, trackID: audioTrackID,
                                                 baseTime: UInt64(max(audioStartTicks, 0)), samples: audioSamples)
        latestAudio = number
        audioSamples.removeAll()
        audioSegments = audioSegments.filter { $0.key > number - keepSegments }
    }

    // MARK: Manifest

    private static func duration(_ seconds: Double) -> String {
        String(format: "PT%.3fS", seconds)
    }

    func manifest() -> String? {
        guard let start = availabilityStart, let video = videoParameters else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = formatter.string(from: Date())
        let segment = settings.segmentDuration
        let frames = settings.segmentFrames
        // Abstand zur Live-Kante: drei Segmente; Player mit Latenzsteuerung (z. B. dash.js) halten sich daran
        let delay = 3 * segment

        var lines: [String] = []
        lines.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        lines.append("<MPD xmlns=\"urn:mpeg:dash:schema:mpd:2011\" profiles=\"urn:mpeg:dash:profile:isoff-live:2011\""
                     + " type=\"dynamic\" availabilityStartTime=\"\(formatter.string(from: start))\" publishTime=\"\(now)\""
                     + " minimumUpdatePeriod=\"PT10S\" minBufferTime=\"\(Self.duration(segment))\""
                     + " suggestedPresentationDelay=\"\(Self.duration(delay))\" timeShiftBufferDepth=\"PT30S\""
                     + " maxSegmentDuration=\"\(Self.duration(segment + 0.1))\">")
        lines.append("  <ServiceDescription id=\"0\">")
        lines.append("    <Latency target=\"\(Int(delay * 1000))\" min=\"\(Int(2 * segment * 1000))\" max=\"\(Int(6 * segment * 1000))\"/>")
        lines.append("    <PlaybackRate min=\"0.96\" max=\"1.04\"/>")
        lines.append("  </ServiceDescription>")
        lines.append("  <Period id=\"0\" start=\"PT0S\">")
        lines.append("    <AdaptationSet id=\"0\" contentType=\"video\" mimeType=\"video/mp4\" segmentAlignment=\"true\" startWithSAP=\"1\">")
        lines.append("      <SegmentTemplate timescale=\"90000\" duration=\"\(frames * 90_000 / StreamSettings.frameRate)\" startNumber=\"0\""
                     + " initialization=\"video_init.mp4\" media=\"video_$Number$.m4s\"/>")
        lines.append("      <Representation id=\"video\" codecs=\"avc1.\(video.profileLevelID)\" bandwidth=\"\(settings.videoBitRate)\""
                     + " width=\"\(video.width)\" height=\"\(video.height)\" frameRate=\"\(StreamSettings.frameRate)\" sar=\"1:1\"/>")
        lines.append("    </AdaptationSet>")
        if let audio = audioParameters {
            lines.append("    <AdaptationSet id=\"1\" contentType=\"audio\" mimeType=\"audio/mp4\" lang=\"und\" segmentAlignment=\"true\" startWithSAP=\"1\">")
            lines.append("      <SegmentTemplate timescale=\"\(audio.sampleRate)\" duration=\"\(frames * audio.sampleRate / StreamSettings.frameRate)\" startNumber=\"0\""
                         + " initialization=\"audio_init.mp4\" media=\"audio_$Number$.m4s\"/>")
            lines.append("      <Representation id=\"audio\" codecs=\"mp4a.40.2\" bandwidth=\"\(StreamSettings.audioBitRate)\" audioSamplingRate=\"\(audio.sampleRate)\">")
            lines.append("        <AudioChannelConfiguration schemeIdUri=\"urn:mpeg:dash:23003:3:audio_channel_configuration:2011\" value=\"\(audio.channels)\"/>")
            lines.append("      </Representation>")
            lines.append("    </AdaptationSet>")
        }
        lines.append("  </Period>")
        lines.append("  <UTCTiming schemeIdUri=\"urn:mpeg:dash:utc:direct:2014\" value=\"\(now)\"/>")
        lines.append("</MPD>")
        return lines.joined(separator: "\n") + "\n"
    }
}
