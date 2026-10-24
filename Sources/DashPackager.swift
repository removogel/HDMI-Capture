import Foundation

/// CMAF-Segmente (fMP4) für MPEG-DASH und HLS: einstellbare Länge D, je ein Track für Bild und Ton.
/// Segment n beginnt bei Medienzeit n · D. DASH adressiert die Segmente über `SegmentTemplate` mit `$Number$`,
/// HLS über Playlists, die dieselben Dateien auflisten. Läuft komplett auf der Stream-Queue.
final class DashPackager {
    enum Track { case video, audio }

    /// Ein fertiges Segment, wie es in der HLS-Playlist steht
    struct SegmentInfo {
        let number: Int
        /// Fortlaufende HLS-Sequenznummer (ohne Lücken, auch wenn Segmentnummern fehlen)
        let sequence: Int
        /// Medienzeit des Segmentanfangs in Sekunden
        let start: Double
        let duration: Double
        /// Zeitsprung (Signalausfall) oder neuer Anfang (neue Auflösung, anderer Codec) vor diesem Segment
        let discontinuity: Bool
        /// Anzahl der Diskontinuitäten bis einschließlich dieses Segments
        let discontinuityIndex: Int
    }

    /// Segmente und Playlist-Einträge eines Tracks
    private struct Timeline {
        var segments: [Int: [UInt8]] = [:]
        var infos: [SegmentInfo] = []
        var latest = -1
        var nextSequence = 0
        var discontinuities = 0
        var restart = true
        /// Zählt bei jedem neuen Init-Segment hoch (Cache-Brecher für HLS)
        var initVersion = 0

        mutating func reset() {
            segments.removeAll()
            infos.removeAll()
            latest = -1
            restart = true
            initVersion += 1
        }

        mutating func add(number: Int, data: [UInt8], start: Double, duration: Double, keep: Int) {
            let gap = latest >= 0 && number != latest + 1
            let discontinuity = (restart && nextSequence > 0) || gap
            if discontinuity { discontinuities += 1 }
            infos.append(SegmentInfo(number: number, sequence: nextSequence, start: start, duration: duration,
                                     discontinuity: discontinuity, discontinuityIndex: discontinuities))
            nextSequence += 1
            restart = false
            segments[number] = data
            latest = number
            segments = segments.filter { $0.key > number - keep }
            infos.removeAll { $0.number <= number - keep }
        }
    }

    let settings: StreamSettings
    /// Wie viele Segmente vorgehalten werden (gut 40 s)
    let keepSegments: Int
    private let videoTrackID = 1
    private let audioTrackID = 2

    private(set) var videoInit: [UInt8]?
    private(set) var audioInit: [UInt8]?
    private var video = Timeline()
    private var audio = Timeline()
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

    func latest(_ track: Track) -> Int { track == .video ? video.latest : audio.latest }

    func segment(_ track: Track, _ number: Int) -> [UInt8]? {
        track == .video ? video.segments[number] : audio.segments[number]
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
            // Erster Start, neue Auflösung oder anderer Codec: Video-Segmente neu beginnen
            videoParameters = parameters
            videoInit = MP4.videoInit(parameters, trackID: videoTrackID)
            video.reset()
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
            if duration <= 0 || duration > 45_000 { duration = Int64(90_000 / settings.frameRate) }
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
        let data = MP4.mediaSegment(sequence: videoNumber + 1, trackID: videoTrackID,
                                    baseTime: UInt64(max(videoStartTicks, 0)), samples: videoSamples)
        let duration = videoSamples.reduce(0) { $0 + Int($1.duration) }
        video.add(number: videoNumber, data: data, start: Double(videoStartTicks) / 90_000,
                  duration: Double(duration) / 90_000, keep: keepSegments)
        videoSamples.removeAll()
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
            audio.reset()
            audioSamples.removeAll()
        }
        let number = settings.segmentNumber(at: frame.time)
        if audioSamples.isEmpty == false && number > audioNumber {
            finishAudioSegment(sampleRate: parameters.sampleRate)
        }
        if audioSamples.isEmpty {
            audioNumber = number
            audioStartTicks = Self.ticks(frame.time, parameters.sampleRate)
        }
        audioSamples.append(MP4.Sample(data: frame.data, duration: 1024, flags: MP4.syncSampleFlags))
    }

    private func finishAudioSegment(sampleRate: Int) {
        let data = MP4.mediaSegment(sequence: audioNumber + 1, trackID: audioTrackID,
                                    baseTime: UInt64(max(audioStartTicks, 0)), samples: audioSamples)
        audio.add(number: audioNumber, data: data, start: Double(audioStartTicks) / Double(sampleRate),
                  duration: Double(audioSamples.count * 1024) / Double(sampleRate), keep: keepSegments)
        audioSamples.removeAll()
    }

    // MARK: DASH-Manifest

    private static func duration(_ seconds: Double) -> String {
        String(format: "PT%.3fS", seconds)
    }

    private static func isoFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    func manifest() -> String? {
        guard let start = availabilityStart, let video = videoParameters else { return nil }
        let formatter = Self.isoFormatter()
        let now = formatter.string(from: Date())
        let segment = settings.segmentDuration
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
        lines.append("      <SegmentTemplate timescale=\"90000\" duration=\"\(Self.ticks(segment, 90_000))\" startNumber=\"0\""
                     + " initialization=\"video_init.mp4\" media=\"video_$Number$.m4s\"/>")
        lines.append("      <Representation id=\"video\" codecs=\"\(video.codecString)\" bandwidth=\"\(settings.videoBitRate)\""
                     + " width=\"\(video.width)\" height=\"\(video.height)\" sar=\"1:1\"/>")
        lines.append("    </AdaptationSet>")
        if let audio = audioParameters {
            lines.append("    <AdaptationSet id=\"1\" contentType=\"audio\" mimeType=\"audio/mp4\" lang=\"und\" segmentAlignment=\"true\" startWithSAP=\"1\">")
            lines.append("      <SegmentTemplate timescale=\"\(audio.sampleRate)\" duration=\"\(Self.ticks(segment, audio.sampleRate))\" startNumber=\"0\""
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

    // MARK: HLS-Playlists

    /// EXT-X-TARGETDURATION: gerundete Segmentlänge plus ein Bild, mindestens 1 s (darf sich nie ändern)
    var hlsTargetDuration: Int { max(1, Int((settings.segmentDuration + 1.0 / 30).rounded())) }

    /// Playlist-Fenster: mindestens 6 Segmente bzw. gut 12 s
    private var hlsWindow: Int { max(6, Int((12 / settings.segmentDuration).rounded(.up))) }

    /// Mindestens ein Segment im Track – sonst kann die Playlist noch nicht geliefert werden
    func hasHLSSegments(_ track: Track) -> Bool {
        (track == .video ? video : audio).infos.isEmpty == false
    }

    /// Master-Playlist: eine Videovariante, Ton als eigene Rendition
    func hlsMasterPlaylist() -> String? {
        guard let video = videoParameters else { return nil }
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-INDEPENDENT-SEGMENTS"]
        var codecs = video.codecString
        var audioGroup = ""
        var bandwidth = settings.videoBitRate * 3 / 2
        var average = settings.videoBitRate
        if let audio = audioParameters {
            lines.append("#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"Audio\",DEFAULT=YES,AUTOSELECT=YES,"
                         + "CHANNELS=\"\(audio.channels)\",URI=\"audio.m3u8\"")
            codecs += ",mp4a.40.2"
            audioGroup = ",AUDIO=\"audio\""
            bandwidth += StreamSettings.audioBitRate
            average += StreamSettings.audioBitRate
        }
        lines.append("#EXT-X-STREAM-INF:BANDWIDTH=\(bandwidth),AVERAGE-BANDWIDTH=\(average),CODECS=\"\(codecs)\","
                     + "RESOLUTION=\(video.width)x\(video.height)\(audioGroup)")
        lines.append("video.m3u8")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Media-Playlist eines Tracks (gleitendes Fenster über die vorhandenen Segmente)
    func hlsMediaPlaylist(_ track: Track) -> String? {
        let timeline = track == .video ? video : audio
        guard let start = availabilityStart, let first = timeline.infos.suffix(hlsWindow).first else { return nil }
        let listed = timeline.infos.suffix(hlsWindow)
        let name = track == .video ? "video" : "audio"
        let formatter = Self.isoFormatter()
        var lines = ["#EXTM3U",
                     "#EXT-X-VERSION:7",
                     "#EXT-X-TARGETDURATION:\(hlsTargetDuration)",
                     "#EXT-X-MEDIA-SEQUENCE:\(first.sequence)",
                     "#EXT-X-DISCONTINUITY-SEQUENCE:\(first.discontinuityIndex)",
                     "#EXT-X-INDEPENDENT-SEGMENTS",
                     "#EXT-X-MAP:URI=\"\(name)_init.mp4?v=\(timeline.initVersion)\""]
        for info in listed {
            if info.sequence != first.sequence && info.discontinuity { lines.append("#EXT-X-DISCONTINUITY") }
            if info.sequence == first.sequence || info.discontinuity {
                // Uhrzeit des Segments – Safari zeigt damit die Live-Verzögerung (getStartDate)
                lines.append("#EXT-X-PROGRAM-DATE-TIME:\(formatter.string(from: start.addingTimeInterval(info.start)))")
            }
            lines.append(String(format: "#EXTINF:%.3f,", info.duration))
            lines.append("\(name)_\(info.number).m4s")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
