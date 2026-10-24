import AVFoundation
import CoreMedia
import VideoToolbox

/// Ein H.264-kodiertes Videobild. `nalUnits` enthält die NAL-Units ohne Start- oder Längencode.
struct EncodedVideoFrame {
    /// Medienzeit in Sekunden seit Streamstart
    let time: Double
    let isKeyframe: Bool
    let nalUnits: [[UInt8]]

    /// NAL-Units ohne Parametersätze (SPS/PPS) und Access-Unit-Delimiter
    var slices: [[UInt8]] {
        nalUnits.filter { nal in
            guard let first = nal.first else { return false }
            let type = first & 0x1F
            return type != 7 && type != 8 && type != 9
        }
    }
}

/// Ein AAC-Rohframe (1024 Samples, ohne ADTS-Kopf)
struct EncodedAudioFrame {
    let time: Double
    let data: [UInt8]
}

struct VideoParameters: Equatable {
    let sps: [UInt8]
    let pps: [UInt8]
    let width: Int
    let height: Int

    /// Profil, Kompatibilität und Level aus dem SPS, z. B. „640028“
    var profileLevelID: String { sps.count >= 4 ? hexString(sps[1...3]) : "640028" }
}

struct AudioParameters: Equatable {
    let sampleRate: Int
    let channels: Int

    var frequencyIndex: Int {
        let rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
        return rates.firstIndex(of: sampleRate) ?? 3
    }

    /// AudioSpecificConfig für AAC-LC (Objekttyp 2), z. B. 0x11 0x90 für 48 kHz stereo
    var audioSpecificConfig: [UInt8] {
        let objectType = 2
        return [UInt8((objectType << 3) | (frequencyIndex >> 1)),
                UInt8(((frequencyIndex & 1) << 7) | (channels << 3))]
    }
}

/// Einstellungen, die beim Start eines Streams festgelegt werden.
/// Die DASH-Segmentlänge ist ein Vielfaches von 16 Bildern (0,533 s): Genau dann enden Bild- und Ton-Segmente
/// gleichzeitig, denn 16 Bilder bei 30 fps dauern so lang wie 25 AAC-Frames zu 1024 Samples bei 48 kHz.
struct StreamSettings {
    static let frameRate = 30
    static let audioBitRate = 128_000
    static let segmentChoices = [16, 32, 64]
    static let defaultSegmentFrames = 32
    /// Toleranz für Segment- und Keyframe-Grenzen (Rundung der Zeitstempel)
    static let boundaryTolerance = 0.002

    let segmentFrames: Int

    init(segmentFrames: Int) {
        self.segmentFrames = Self.segmentChoices.contains(segmentFrames) ? segmentFrames : Self.defaultSegmentFrames
    }

    var segmentDuration: Double { Double(segmentFrames) / Double(Self.frameRate) }

    /// Keyframe-Abstand: teilt die Segmentlänge und ist höchstens gut 1 s, damit TS- und RTSP-Zuschauer schnell einsteigen
    var keyframeInterval: Double { Double(min(segmentFrames, 32)) / Double(Self.frameRate) }

    /// Kurze Segmente bedeuten viele Keyframes – dafür etwas mehr Datenrate
    var videoBitRate: Int { segmentFrames <= 16 ? 8_000_000 : 6_000_000 }

    /// Nummer des Segments, in das ein Zeitpunkt fällt
    func segmentNumber(at time: Double) -> Int {
        Int(floor((time + Self.boundaryTolerance) / segmentDuration))
    }

    static func label(frames: Int) -> String {
        let seconds = Double(frames) / Double(frameRate)
        return String(format: "%.3f s", seconds).replacingOccurrences(of: ".", with: ",")
    }
}

/// Kodiert Bild (H.264, Hardware) und Ton (AAC-LC) für den Netzwerk-Stream.
/// `encodeVideo`/`encodeAudio` laufen auf der Capture-Queue, die Ergebnisse kommen auf `outputQueue`.
/// Alle Zeiten sind Medienzeit: Sekunden seit dem ersten Videobild.
final class StreamEncoder {
    var onVideo: ((EncodedVideoFrame, VideoParameters) -> Void)?
    var onAudio: ((EncodedAudioFrame, AudioParameters) -> Void)?

    let settings: StreamSettings
    private let outputQueue: DispatchQueue
    private let clock: CMClock
    private let lock = NSLock()
    private var startHostTime: CMTime?

    // Nur auf der Capture-Queue benutzt
    private var session: VTCompressionSession?
    private var sessionWidth = 0
    private var sessionHeight = 0
    private var nextKeyframe = 0.0
    private var lastVideoTime = -1.0
    private var converter: AVAudioConverter?
    private var pcmFormat: AVAudioFormat?
    private var audioParameters: AudioParameters?
    private var fifo: [Float] = []
    private var fifoTime = 0.0
    private var expectedAudioTime: Double?
    private var chunkTimes: [Double] = []
    private var primingDelay = 0.0

    private final class Flag { var value = false }

    init(outputQueue: DispatchQueue, clock: CMClock, settings: StreamSettings) {
        self.outputQueue = outputQueue
        self.clock = clock
        self.settings = settings
    }

    deinit { invalidate() }

    /// Beendet die Videokodierung (auf der Capture-Queue aufrufen)
    func invalidate() {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
    }

    /// Aktuelle Medienzeit – für RTCP-Sender-Reports. Nil vor dem ersten Bild.
    func mediaTimeNow() -> Double? {
        guard let start = startTime() else { return nil }
        return CMTimeGetSeconds(CMTimeSubtract(CMClockGetTime(clock), start))
    }

    private func startTime() -> CMTime? {
        lock.lock()
        defer { lock.unlock() }
        return startHostTime
    }

    private func setStartTime(_ time: CMTime) {
        lock.lock()
        startHostTime = time
        lock.unlock()
    }

    // MARK: Video

    func encodeVideo(_ pixelBuffer: CVPixelBuffer, hostTime: CMTime) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        if session == nil || width != sessionWidth || height != sessionHeight {
            createSession(width: width, height: height)
        }
        guard let session else { return }

        let start: CMTime
        if let existing = startTime() {
            start = existing
        } else {
            setStartTime(hostTime)
            start = hostTime
        }
        let time = CMTimeGetSeconds(CMTimeSubtract(hostTime, start))
        guard time > lastVideoTime else { return }
        lastVideoTime = time

        var properties: CFDictionary?
        // Keyframe am ersten Bild ab jeder Grenze – DASH schneidet die Segmente genau dort
        let tolerance = StreamSettings.boundaryTolerance
        if time + tolerance >= nextKeyframe {
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
            let interval = settings.keyframeInterval
            nextKeyframe = (floor((time + tolerance) / interval) + 1) * interval
        }
        let status = VTCompressionSessionEncodeFrame(session,
                                                     imageBuffer: pixelBuffer,
                                                     presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 90_000),
                                                     duration: .invalid,
                                                     frameProperties: properties,
                                                     infoFlagsOut: nil) { [weak self] encodeStatus, _, sampleBuffer in
            guard encodeStatus == noErr, let sampleBuffer else { return }
            self?.handleEncodedVideo(sampleBuffer)
        }
        if status != noErr { debugLog("Videokodierung für den Stream fehlgeschlagen: \(status)") }
    }

    private func createSession(width: Int, height: Int) {
        invalidate()
        var created: VTCompressionSession?
        let specification = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true] as CFDictionary
        let status = VTCompressionSessionCreate(allocator: nil,
                                                width: Int32(width),
                                                height: Int32(height),
                                                codecType: kCMVideoCodecType_H264,
                                                encoderSpecification: specification,
                                                imageBufferAttributes: nil,
                                                compressedDataAllocator: nil,
                                                outputCallback: nil,
                                                refcon: nil,
                                                compressionSessionOut: &created)
        guard status == noErr, let created else {
            debugLog("H.264-Encoder startet nicht: \(status)")
            return
        }
        Self.set(created, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        Self.set(created, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        // Ohne B-Frames: Dekodier- und Anzeigereihenfolge sind gleich, PTS = DTS
        Self.set(created, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        let bitRate = settings.videoBitRate
        Self.set(created, kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitRate))
        Self.set(created, kVTCompressionPropertyKey_DataRateLimits,
                 [NSNumber(value: bitRate * 3 / 2 / 8), NSNumber(value: 1)] as CFArray)
        Self.set(created, kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: StreamSettings.frameRate))
        Self.set(created, kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: StreamSettings.frameRate * 4))
        Self.set(created, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 4))
        VTCompressionSessionPrepareToEncodeFrames(created)
        session = created
        sessionWidth = width
        sessionHeight = height
        nextKeyframe = 0
        debugLog("Stream-Encoder: H.264 \(width)x\(height), \(bitRate / 1_000_000) Mbit/s, "
                 + "Keyframe alle \(StreamSettings.label(frames: min(settings.segmentFrames, 32)))")
    }

    private static func set(_ session: VTCompressionSession, _ key: CFString, _ value: CFTypeRef) {
        let status = VTSessionSetProperty(session, key: key, value: value)
        if status != noErr { debugLog("Encoder-Einstellung \(key) nicht übernommen: \(status)") }
    }

    /// Läuft auf einem Thread von VideoToolbox
    private func handleEncodedVideo(_ sampleBuffer: CMSampleBuffer) {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let block = CMSampleBufferGetDataBuffer(sampleBuffer),
              let sps = Self.parameterSet(format, index: 0),
              let pps = Self.parameterSet(format, index: 1) else { return }

        var headerLength: Int32 = 4
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0,
                                                           parameterSetPointerOut: nil,
                                                           parameterSetSizeOut: nil,
                                                           parameterSetCountOut: nil,
                                                           nalUnitHeaderLengthOut: &headerLength)
        let length = CMBlockBufferGetDataLength(block)
        var bytes = [UInt8](repeating: 0, count: length)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &bytes) == kCMBlockBufferNoErr else { return }

        // Längenpräfix-Format (AVCC) in einzelne NAL-Units zerlegen
        var nalUnits: [[UInt8]] = []
        let prefix = Int(headerLength)
        var offset = 0
        while offset + prefix <= length {
            var size = 0
            for index in 0..<prefix { size = (size << 8) | Int(bytes[offset + index]) }
            offset += prefix
            guard size > 0, offset + size <= length else { break }
            nalUnits.append(Array(bytes[offset..<(offset + size)]))
            offset += size
        }

        var isKeyframe = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let notSync = attachments.first?[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKeyframe = notSync == false
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let parameters = VideoParameters(sps: sps, pps: pps, width: Int(dimensions.width), height: Int(dimensions.height))
        let frame = EncodedVideoFrame(time: CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)),
                                      isKeyframe: isKeyframe,
                                      nalUnits: nalUnits)
        outputQueue.async { [weak self] in self?.onVideo?(frame, parameters) }
    }

    private static func parameterSet(_ format: CMFormatDescription, index: Int) -> [UInt8]? {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                                                                        parameterSetPointerOut: &pointer,
                                                                        parameterSetSizeOut: &size,
                                                                        parameterSetCountOut: nil,
                                                                        nalUnitHeaderLengthOut: nil)
        guard status == noErr, let pointer, size > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: pointer, count: size))
    }

    // MARK: Audio

    /// `samples`: verschachtelte Stereo-Samples (L R L R …), bereits als 48 kHz stereo gedeutet
    func encodeAudio(_ samples: [Float], sampleRate: Double, hostTime: CMTime) {
        guard let start = startTime() else { return }   // Ton erst, wenn das erste Bild da ist
        let rate = Int(sampleRate.rounded())
        if audioParameters?.sampleRate != rate { setupAudio(rate: rate) }
        guard let converter, let pcmFormat, let parameters = audioParameters else { return }

        let time = CMTimeGetSeconds(CMTimeSubtract(hostTime, start))
        if let expected = expectedAudioTime, abs(time - expected) < 0.1 {
            // lückenlos weiter
        } else {
            // Start oder Lücke: Zeitachse neu ansetzen
            fifo.removeAll()
            fifoTime = time
        }
        fifo.append(contentsOf: samples)
        expectedAudioTime = time + Double(samples.count / 2) / Double(rate)

        let frames = 1024
        while fifo.count >= frames * 2 {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(frames)),
                  let channels = buffer.floatChannelData else { return }
            buffer.frameLength = AVAudioFrameCount(frames)
            let left = channels[0]
            let right = channels[1]
            for index in 0..<frames {
                left[index] = fifo[index * 2]
                right[index] = fifo[index * 2 + 1]
            }
            fifo.removeFirst(frames * 2)
            chunkTimes.append(fifoTime)
            fifoTime += Double(frames) / Double(rate)
            encodeChunk(buffer, converter: converter, parameters: parameters)
        }
    }

    private func setupAudio(rate: Int) {
        converter = nil
        guard let pcm = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 2) else { return }
        var description = AudioStreamBasicDescription(mSampleRate: Double(rate),
                                                      mFormatID: kAudioFormatMPEG4AAC,
                                                      mFormatFlags: 2,   // kMPEG4Object_AAC_LC
                                                      mBytesPerPacket: 0,
                                                      mFramesPerPacket: 1024,
                                                      mBytesPerFrame: 0,
                                                      mChannelsPerFrame: 2,
                                                      mBitsPerChannel: 0,
                                                      mReserved: 0)
        guard let aac = AVAudioFormat(streamDescription: &description),
              let created = AVAudioConverter(from: pcm, to: aac) else {
            debugLog("AAC-Encoder startet nicht (\(rate) Hz)")
            return
        }
        created.bitRate = StreamSettings.audioBitRate
        converter = created
        pcmFormat = pcm
        audioParameters = AudioParameters(sampleRate: rate, channels: 2)
        // Apples AAC-Encoder setzt 2112 Samples Vorlauf voran; die Zeitstempel gleichen das aus
        primingDelay = 2112 / Double(rate)
        fifo.removeAll()
        chunkTimes.removeAll()
        expectedAudioTime = nil
    }

    private func encodeChunk(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, parameters: AudioParameters) {
        let output = AVAudioCompressedBuffer(format: converter.outputFormat,
                                             packetCapacity: 8,
                                             maximumPacketSize: max(converter.maximumOutputPacketSize, 1536))
        let supplied = Flag()
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied.value {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied.value = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            debugLog("AAC-Kodierung fehlgeschlagen: \(error?.localizedDescription ?? "unbekannt")")
            return
        }
        guard let descriptions = output.packetDescriptions else { return }
        for index in 0..<Int(output.packetCount) {
            let description = descriptions[index]
            let start = output.data.advanced(by: Int(description.mStartOffset))
            let bytes = Array(UnsafeRawBufferPointer(start: start, count: Int(description.mDataByteSize)))
            guard chunkTimes.isEmpty == false else { break }
            let time = chunkTimes.removeFirst() - primingDelay
            guard time >= 0, bytes.isEmpty == false else { continue }
            let frame = EncodedAudioFrame(time: time, data: bytes)
            outputQueue.async { [weak self] in self?.onAudio?(frame, parameters) }
        }
    }
}
