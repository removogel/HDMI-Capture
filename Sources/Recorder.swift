import AVFoundation
import CoreMedia

enum RecorderError: LocalizedError {
    case setup
    var errorDescription: String? { "Couldn't set up the recording" }
}

/// Schreibt Video (H.264 oder HEVC, Hardware) und den korrigierten Stereoton (AAC) in eine MP4-Datei.
/// Die Datei wird alle 10 s fragmentiert geschrieben: Bricht die Aufnahme ab (Absturz, Stromausfall,
/// volle Platte), bleibt sie bis zum letzten Fragment abspielbar.
/// Wird nur von der Capture-Queue aus benutzt.
final class Recorder {
    static let fragmentInterval = 10.0

    let url: URL
    /// Schreiben ist fehlgeschlagen (z. B. Platte voll) – Aufruf einmalig auf der Capture-Queue
    var onFailure: ((String) -> Void)?
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput
    private var started = false
    private var failed = false
    private var startTime = CMTime.invalid
    private var audioFormat: CMAudioFormatDescription?
    private var audioRate: Double = 0
    private var nextAudioPTS = CMTime.invalid

    init(url: URL, width: Int, height: Int, bitRate: Int, codec: VideoCodec, frameRate: Int) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.movieFragmentInterval = CMTime(seconds: Self.fragmentInterval, preferredTimescale: 600)
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitRate,
            AVVideoMaxKeyFrameIntervalDurationKey: 2,
            AVVideoExpectedSourceFrameRateKey: frameRate,
        ]
        // HEVC: Standardprofil Main (8 Bit)
        if codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression
        ]
        // Ungültige Einstellungen würden eine Exception auslösen – dann nur mit Bitrate
        if writer.canApply(outputSettings: videoSettings, forMediaType: .video) == false {
            debugLog("Recording: video settings not accepted, using defaults")
            videoSettings[AVVideoCompressionPropertiesKey] = [AVVideoAverageBitRateKey: bitRate]
        }
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else { throw RecorderError.setup }
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000
        ])
        audioInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else { throw RecorderError.setup }
        writer.add(videoInput)
        writer.add(audioInput)
    }

    /// Länge der Aufnahme bis zum zuletzt angenommenen Bild
    private(set) var duration: Double = 0

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if started == false {
            guard writer.status == .unknown, writer.startWriting() else {
                debugLog("Recording failed to start: \(String(describing: writer.error))")
                reportFailure()
                return
            }
            writer.startSession(atSourceTime: pts)
            startTime = pts
            started = true
        }
        guard checkStatus() else { return }
        if videoInput.isReadyForMoreMediaData, videoInput.append(sampleBuffer) {
            duration = max(duration, CMTimeGetSeconds(CMTimeSubtract(pts, startTime)))
        }
        _ = checkStatus()
    }

    /// `frames`: verschachtelte Stereo-Samples (Float32).
    func appendAudio(_ frames: [Float], rate: Double, pts: CMTime) {
        guard started, checkStatus() else { return }
        let count = frames.count / 2
        guard count > 0 else { return }

        // Lückenlose Zeitstempel; nur bei echter Abweichung (> 50 ms) neu ansetzen.
        var t = pts
        if nextAudioPTS.isValid {
            let diff = CMTimeGetSeconds(CMTimeSubtract(pts, nextAudioPTS))
            if diff < 0.05 { t = nextAudioPTS }
        }
        guard CMTimeCompare(t, startTime) >= 0 else { return }
        guard audioInput.isReadyForMoreMediaData,
              let sampleBuffer = makeSampleBuffer(frames, count: count, rate: rate, pts: t) else { return }
        if audioInput.append(sampleBuffer) {
            nextAudioPTS = CMTimeAdd(t, CMTime(value: CMTimeValue(count), timescale: CMTimeScale(rate)))
        }
    }

    func finish(_ done: @escaping (URL?) -> Void) {
        guard started, writer.status == .writing else {
            done(nil)
            return
        }
        videoInput.markAsFinished()
        audioInput.markAsFinished()
        let writer = self.writer
        let url = self.url
        writer.finishWriting {
            if writer.status != .completed {
                debugLog("Recording failed: \(String(describing: writer.error))")
            }
            done(writer.status == .completed ? url : nil)
        }
    }

    /// true, solange geschrieben wird; meldet einen Fehler des Writers genau einmal
    private func checkStatus() -> Bool {
        if writer.status == .writing { return true }
        if writer.status == .failed { reportFailure() }
        return false
    }

    private func reportFailure() {
        guard failed == false else { return }
        failed = true
        let reason = writer.error?.localizedDescription ?? "unknown error"
        debugLog("Recording failed: \(String(describing: writer.error))")
        onFailure?(reason)
    }

    private func makeSampleBuffer(_ frames: [Float], count: Int, rate: Double, pts: CMTime) -> CMSampleBuffer? {
        if audioFormat == nil || audioRate != rate {
            var asbd = AudioStreamBasicDescription(
                mSampleRate: rate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 8,
                mFramesPerPacket: 1,
                mBytesPerFrame: 8,
                mChannelsPerFrame: 2,
                mBitsPerChannel: 32,
                mReserved: 0)
            var desc: CMAudioFormatDescription?
            guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                                                 layoutSize: 0, layout: nil,
                                                 magicCookieSize: 0, magicCookie: nil,
                                                 extensions: nil, formatDescriptionOut: &desc) == noErr else { return nil }
            audioFormat = desc
            audioRate = rate
        }
        guard let format = audioFormat else { return nil }

        let bytes = count * 8
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                                 blockLength: bytes, blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == kCMBlockBufferNoErr,
              let buffer = block else { return nil }
        let copied = frames.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: buffer, offsetIntoDestination: 0, dataLength: bytes)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault,
                                                                   dataBuffer: buffer,
                                                                   formatDescription: format,
                                                                   sampleCount: count,
                                                                   presentationTimeStamp: pts,
                                                                   packetDescriptions: nil,
                                                                   sampleBufferOut: &sampleBuffer) == noErr else { return nil }
        return sampleBuffer
    }
}
