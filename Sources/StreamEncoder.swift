import AVFoundation
import CoreMedia
import VideoToolbox

/// Videocodec für Stream und Aufnahme
enum VideoCodec: String, CaseIterable {
    case h264
    case hevc

    /// Gespeicherten Wert lesen; Unbekanntes wird H.264
    init(stored: String?) { self = VideoCodec(rawValue: stored ?? "") ?? .h264 }

    var label: String { self == .h264 ? "H.264" : "HEVC (H.265)" }
    var shortName: String { self == .h264 ? "H.264" : "HEVC" }
}

/// Ein kodiertes Videobild. `nalUnits` enthält die NAL-Units ohne Start- oder Längencode.
struct EncodedVideoFrame {
    /// Medienzeit in Sekunden seit Streamstart
    let time: Double
    let isKeyframe: Bool
    let codec: VideoCodec
    let nalUnits: [[UInt8]]

    /// NAL-Units ohne Parametersätze und Access-Unit-Delimiter
    var slices: [[UInt8]] {
        nalUnits.filter { nal in
            guard let type = NAL.type(nal, codec) else { return false }
            return NAL.isParameterSetOrDelimiter(type, codec) == false
        }
    }
}

/// NAL-Unit-Typen von H.264 und HEVC
enum NAL {
    static func type(_ nal: [UInt8], _ codec: VideoCodec) -> Int? {
        guard let first = nal.first else { return nil }
        return codec == .h264 ? Int(first & 0x1F) : Int((first >> 1) & 0x3F)
    }

    /// H.264: SPS 7, PPS 8, AUD 9 – HEVC: VPS 32, SPS 33, PPS 34, AUD 35
    static func isParameterSetOrDelimiter(_ type: Int, _ codec: VideoCodec) -> Bool {
        codec == .h264 ? (7...9).contains(type) : (32...35).contains(type)
    }
}

/// Ein AAC-Rohframe (1024 Samples, ohne ADTS-Kopf)
struct EncodedAudioFrame {
    let time: Double
    let data: [UInt8]
}

struct VideoParameters: Equatable {
    let codec: VideoCodec
    /// H.264: SPS, PPS – HEVC: VPS, SPS, PPS (jeweils ohne Start- oder Längencode)
    let parameterSets: [[UInt8]]
    /// Inhalt der hvcC-Box (nur HEVC)
    let hvcC: [UInt8]
    let width: Int
    let height: Int

    private func parameterSet(h264 h264Type: Int, hevc hevcType: Int) -> [UInt8] {
        let wanted = codec == .h264 ? h264Type : hevcType
        return parameterSets.first { NAL.type($0, codec) == wanted } ?? []
    }

    var vps: [UInt8] { codec == .hevc ? parameterSet(h264: -1, hevc: 32) : [] }
    var sps: [UInt8] { parameterSet(h264: 7, hevc: 33) }
    var pps: [UInt8] { parameterSet(h264: 8, hevc: 34) }

    /// H.264: Profil, Kompatibilität und Level aus dem SPS, z. B. „640028“
    var profileLevelID: String { sps.count >= 4 ? hexString(sps[1...3]) : "640028" }

    /// Codec-Angabe für DASH und HLS (RFC 6381), z. B. „avc1.640028“ oder „hvc1.1.6.L123.B0“
    var codecString: String {
        codec == .h264 ? "avc1.\(profileLevelID)" : HEVCConfig.codecString(hvcC)
    }
}

/// hvcC (ISO/IEC 14496-15) aus VPS/SPS/PPS bauen und die Codec-Angabe daraus ableiten
enum HEVCConfig {
    /// Fallback, falls VideoToolbox keine hvcC liefert: Profil, Tier und Level stehen am Anfang des SPS
    static func build(vps: [UInt8], sps: [UInt8], pps: [UInt8]) -> [UInt8] {
        // SPS-RBSP ohne Emulation-Prevention-Bytes; nach dem 2-Byte-NAL-Kopf folgt 1 Byte, dann profile_tier_level
        let rbsp = removeEmulationPrevention(Array(sps.dropFirst(2)))
        guard rbsp.count >= 13 else { return [] }
        var config: [UInt8] = [1]
        config += rbsp[1...12]                // Profil/Tier, Kompatibilität (4), Constraints (6), Level
        config += [0xF0, 0x00]                // min_spatial_segmentation_idc = 0
        config += [0xFC]                      // parallelismType = 0
        config += [0xFD]                      // chroma_format_idc = 1 (4:2:0)
        config += [0xF8, 0xF8]                // 8 Bit Luma/Chroma
        config += [0x00, 0x00]                // avgFrameRate unbekannt
        config += [0x0F]                      // 1 zeitliche Ebene, verschachtelt, 4-Byte-Längen
        config += [3]
        for (type, nal) in [(32, vps), (33, sps), (34, pps)] {
            config.append(0x80 | UInt8(type))
            config.appendU16(1)
            config.appendU16(nal.count)
            config += nal
        }
        return config
    }

    /// Setzt bei allen NAL-Arrays „array_completeness“: Die Parametersätze stehen nur in der hvcC, nicht im Bild
    static func markComplete(_ hvcC: [UInt8]) -> [UInt8] {
        guard hvcC.count > 23 else { return hvcC }
        var out = hvcC
        var offset = 23
        for _ in 0..<Int(hvcC[22]) {
            guard offset + 3 <= out.count else { return hvcC }
            out[offset] |= 0x80
            let count = (Int(out[offset + 1]) << 8) | Int(out[offset + 2])
            offset += 3
            for _ in 0..<count {
                guard offset + 2 <= out.count else { return hvcC }
                offset += 2 + ((Int(out[offset]) << 8) | Int(out[offset + 1]))
            }
        }
        return offset <= out.count ? out : hvcC
    }

    static func removeEmulationPrevention(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var zeros = 0
        for byte in bytes {
            if zeros >= 2 && byte == 0x03 {
                zeros = 0
                continue
            }
            zeros = byte == 0 ? zeros + 1 : 0
            out.append(byte)
        }
        return out
    }

    /// Codec-Angabe nach ISO/IEC 14496-15 Anhang E, z. B. „hvc1.1.6.L123.B0“
    static func codecString(_ hvcC: [UInt8]) -> String {
        guard hvcC.count >= 13 else { return "hvc1.1.6.L120.90" }
        let space = ["", "A", "B", "C"][Int(hvcC[1] >> 6)]
        let tier = (hvcC[1] & 0x20) != 0 ? "H" : "L"
        let profile = Int(hvcC[1] & 0x1F)
        var compatibility: UInt32 = 0
        for index in 2...5 { compatibility = (compatibility << 8) | UInt32(hvcC[index]) }
        // Kompatibilitäts-Flags in umgekehrter Bitreihenfolge, hexadezimal ohne führende Nullen
        var reversed: UInt32 = 0
        for bit in 0..<32 where (compatibility >> UInt32(bit)) & 1 == 1 { reversed |= 1 << UInt32(31 - bit) }
        var constraints = Array(hvcC[6...11])
        while let last = constraints.last, last == 0 { constraints.removeLast() }
        var result = "hvc1.\(space)\(profile).\(String(reversed, radix: 16, uppercase: true)).\(tier)\(hvcC[12])"
        for byte in constraints { result += "." + String(format: "%02X", byte) }
        return result
    }
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
/// Die Segmentlänge wird in 1/30 s angegeben („Bilder bei 30 fps“) und ist ein Vielfaches von 16/30 s = 0,533 s:
/// So lang dauern genau 25 AAC-Frames zu 1024 Samples bei 48 kHz, also enden Bild- und Ton-Segmente gleichzeitig –
/// bei 30 fps nach 16, bei 60 fps nach 32 Bildern.
struct StreamSettings {
    static let audioBitRate = 128_000
    /// Segmentlängen in 1/30 s: 0,533 / 1,067 / 2,133 s
    static let segmentChoices = [16, 32, 64]
    static let defaultSegmentFrames = 32
    static let frameRateChoices = [30, 60]
    static let defaultFrameRate = 30
    /// Wählbare Videobitraten in Mbit/s (Stream und Aufnahme)
    static let bitRateChoices = [5, 8, 16, 30]
    static let defaultBitRate = 16
    /// Toleranz für Segment- und Keyframe-Grenzen (Rundung der Zeitstempel)
    static let boundaryTolerance = 0.002

    /// Segmentlänge in 1/30 s
    let segmentFrames: Int
    /// Videobitrate in bit/s
    let videoBitRate: Int
    let codec: VideoCodec
    /// Erwartete Bildrate der Quelle (nur ein Hinweis für den Encoder; alle Zeiten kommen aus den Zeitstempeln)
    let frameRate: Int

    init(segmentFrames: Int, videoMbits: Int = StreamSettings.defaultBitRate,
         codec: VideoCodec = .h264, frameRate: Int = StreamSettings.defaultFrameRate) {
        self.segmentFrames = Self.segmentChoices.contains(segmentFrames) ? segmentFrames : Self.defaultSegmentFrames
        videoBitRate = Self.validMbits(videoMbits) * 1_000_000
        self.codec = codec
        self.frameRate = Self.validFrameRate(frameRate)
    }

    /// Ungültige Werte (z. B. aus alten Einstellungen) auf den Standard setzen
    static func validMbits(_ value: Int) -> Int {
        bitRateChoices.contains(value) ? value : defaultBitRate
    }

    static func validFrameRate(_ value: Int) -> Int {
        frameRateChoices.contains(value) ? value : defaultFrameRate
    }

    /// Ab so vielen unbestätigten Bytes gilt ein Zuschauer als zu langsam: gut 2 s Video, mindestens 4 MB
    var slowClientBytes: Int { max(4_000_000, videoBitRate / 4) }

    var segmentDuration: Double { Double(segmentFrames) / 30 }

    /// Keyframe-Abstand: teilt die Segmentlänge und ist höchstens gut 1 s, damit TS- und RTSP-Zuschauer schnell einsteigen
    var keyframeInterval: Double { Double(min(segmentFrames, 32)) / 30 }

    /// Nummer des Segments, in das ein Zeitpunkt fällt
    func segmentNumber(at time: Double) -> Int {
        Int(floor((time + Self.boundaryTolerance) / segmentDuration))
    }

    static func label(frames: Int) -> String {
        String(format: "%.3f s", Double(frames) / 30)
    }
}

/// Kodiert Bild (H.264 oder HEVC, Hardware) und Ton (AAC-LC) für den Netzwerk-Stream.
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
        if status != noErr { debugLog("Stream video encoding failed: \(status)") }
    }

    private func createSession(width: Int, height: Int) {
        invalidate()
        var codec = settings.codec
        var created = Self.makeSession(width: width, height: height, codec: codec)
        if created == nil && codec == .hevc {
            // Kein HEVC-Encoder (ältere Intel-Macs): mit H.264 weiter
            debugLog("HEVC encoder not available, falling back to H.264")
            codec = .h264
            created = Self.makeSession(width: width, height: height, codec: codec)
        }
        guard let created else { return }
        Self.set(created, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        Self.set(created, kVTCompressionPropertyKey_ProfileLevel,
                 codec == .h264 ? kVTProfileLevel_H264_High_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel)
        // Ohne B-Frames: Dekodier- und Anzeigereihenfolge sind gleich, PTS = DTS
        Self.set(created, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        let bitRate = settings.videoBitRate
        Self.set(created, kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitRate))
        Self.set(created, kVTCompressionPropertyKey_DataRateLimits,
                 [NSNumber(value: bitRate * 3 / 2 / 8), NSNumber(value: 1)] as CFArray)
        Self.set(created, kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: settings.frameRate))
        Self.set(created, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 4))
        VTCompressionSessionPrepareToEncodeFrames(created)
        session = created
        sessionWidth = width
        sessionHeight = height
        nextKeyframe = 0
        debugLog("Stream encoder: \(codec.shortName) \(width)x\(height), \(bitRate / 1_000_000) Mbit/s, "
                 + "keyframe every \(StreamSettings.label(frames: min(settings.segmentFrames, 32)))")
    }

    private static func makeSession(width: Int, height: Int, codec: VideoCodec) -> VTCompressionSession? {
        var created: VTCompressionSession?
        let specification = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true] as CFDictionary
        let status = VTCompressionSessionCreate(allocator: nil,
                                                width: Int32(width),
                                                height: Int32(height),
                                                codecType: codec == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC,
                                                encoderSpecification: specification,
                                                imageBufferAttributes: nil,
                                                compressedDataAllocator: nil,
                                                outputCallback: nil,
                                                refcon: nil,
                                                compressionSessionOut: &created)
        guard status == noErr, let created else {
            debugLog("\(codec.shortName) encoder failed to start: \(status)")
            return nil
        }
        return created
    }

    private static func set(_ session: VTCompressionSession, _ key: CFString, _ value: CFTypeRef) {
        let status = VTSessionSetProperty(session, key: key, value: value)
        if status != noErr { debugLog("Encoder setting \(key) not applied: \(status)") }
    }

    /// Läuft auf einem Thread von VideoToolbox
    private func handleEncodedVideo(_ sampleBuffer: CMSampleBuffer) {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let codec: VideoCodec = CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC ? .hevc : .h264
        guard let sets = Self.parameterSets(format, codec: codec), sets.units.count >= (codec == .hevc ? 3 : 2) else { return }

        let length = CMBlockBufferGetDataLength(block)
        var bytes = [UInt8](repeating: 0, count: length)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &bytes) == kCMBlockBufferNoErr else { return }

        // Längenpräfix-Format (AVCC/HVCC) in einzelne NAL-Units zerlegen
        var nalUnits: [[UInt8]] = []
        let prefix = sets.headerLength
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
        var hvcC: [UInt8] = []
        if codec == .hevc {
            hvcC = HEVCConfig.markComplete(Self.configurationAtom(format, "hvcC"))
            if hvcC.isEmpty {
                let units = sets.units
                let find = { (type: Int) -> [UInt8] in units.first { NAL.type($0, .hevc) == type } ?? [] }
                hvcC = HEVCConfig.build(vps: find(32), sps: find(33), pps: find(34))
            }
        }
        let parameters = VideoParameters(codec: codec, parameterSets: sets.units, hvcC: hvcC,
                                         width: Int(dimensions.width), height: Int(dimensions.height))
        let frame = EncodedVideoFrame(time: CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)),
                                      isKeyframe: isKeyframe,
                                      codec: codec,
                                      nalUnits: nalUnits)
        outputQueue.async { [weak self] in self?.onVideo?(frame, parameters) }
    }

    /// Alle Parametersätze (H.264: SPS, PPS – HEVC: VPS, SPS, PPS) und die Länge der NAL-Längenpräfixe
    private static func parameterSets(_ format: CMFormatDescription, codec: VideoCodec) -> (units: [[UInt8]], headerLength: Int)? {
        var count = 0
        var headerLength: Int32 = 4
        let probe = codec == .h264
            ? CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                                 parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                                 nalUnitHeaderLengthOut: &headerLength)
            : CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                                 parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                                 nalUnitHeaderLengthOut: &headerLength)
        guard probe == noErr, count > 0 else { return nil }
        var units: [[UInt8]] = []
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = codec == .h264
                ? CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                     parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                     nalUnitHeaderLengthOut: nil)
                : CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                     parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                     nalUnitHeaderLengthOut: nil)
            guard status == noErr, let pointer, size > 0 else { continue }
            let unit = Array(UnsafeBufferPointer(start: pointer, count: size))
            // Nur VPS/SPS/PPS bzw. SPS/PPS – z. B. SEI-Präfixe weglassen
            if let type = NAL.type(unit, codec), NAL.isParameterSetOrDelimiter(type, codec) { units.append(unit) }
        }
        return (units, Int(headerLength))
    }

    /// Box-Inhalt (z. B. hvcC) aus den Sample-Description-Erweiterungen von VideoToolbox
    private static func configurationAtom(_ format: CMFormatDescription, _ name: String) -> [UInt8] {
        guard let atoms = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? NSDictionary,
              let data = atoms[name] as? Data else { return [] }
        return [UInt8](data)
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
            debugLog("AAC encoder failed to start (\(rate) Hz)")
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
            debugLog("AAC encoding failed: \(error?.localizedDescription ?? "unknown")")
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
