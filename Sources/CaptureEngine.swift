import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Schreibt Diagnosezeilen nach stderr (nicht ins System-Log).
func debugLog(_ text: String) {
    FileHandle.standardError.write(("HDMI Capture: " + text + "\n").data(using: .utf8) ?? Data())
}

/// Auswahl von Bild- und Tonquelle und gewünschte Bildrate
struct CaptureOptions {
    /// uniqueID des Videogeräts; nil = automatisch (bevorzugt den MS2109-Stick)
    var videoDeviceID: String?
    /// uniqueID des Audiogeräts; nil = automatisch (passend zum Videogerät), `noAudio` = ohne Ton
    var audioDeviceID: String?
    var frameRate: Int

    static let noAudio = "none"
}

/// Was nach dem (Neu-)Einrichten tatsächlich läuft
struct CaptureSetup {
    var videoID: String?
    var videoName: String?
    var audioID: String?
    var audioName: String?
    /// Eingestellte Bildrate der Quelle; nil ohne Videogerät
    var frameRate: Double?
    /// Hinweise für die Statuszeile (fehlender Zugriff, Gerät nicht gefunden …)
    var notes: [String] = []
}

/// Gewähltes Format eines Videogeräts
struct FormatChoice {
    let format: AVCaptureDevice.Format
    let duration: CMTime
    let fps: Double
    let width: Int
    let height: Int
}

/// Ein Standbild aus dem Videostrom in voller Auflösung, als Bild und fertig kodiertes PNG.
struct Snapshot {
    let image: CGImage
    let png: Data
}

/// Holt Bild und Ton vom gewählten Capture-Gerät. Beim MS2109 wählt es den flüssigen MJPEG-Modus (420v)
/// und deutet den Ton richtig: Der Chip meldet 96 kHz mono, liefert aber 48 kHz stereo.
final class CaptureEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let monitor = AudioMonitor()

    var onLevels: (@MainActor (Float, Float) -> Void)?
    var onStats: (@MainActor (Double, Int, Int) -> Void)?
    var onViewers: (@MainActor (Int) -> Void)?
    var onStreamRejected: (@MainActor (String) -> Void)?
    /// Aufnahme wegen eines Schreibfehlers abgebrochen (z. B. Platte voll): Datei und Grund
    var onRecordingFailed: (@MainActor (URL, String) -> Void)?

    /// Sample-Buffer, Aufnahme, Stream-Encoder, Pegel
    private let queue = DispatchQueue(label: "local.hdmicapture.capture", qos: .userInteractive)
    /// Konfiguration der Session und der Geräte
    private let sessionQueue = DispatchQueue(label: "local.hdmicapture.session", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var timer: DispatchSourceTimer?
    private let snapshotQueue = DispatchQueue(label: "local.hdmicapture.snapshot", qos: .userInitiated)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    private struct SnapshotRequest {
        let time: TimeInterval
        let done: @MainActor (Snapshot?) -> Void
    }

    // Nur auf `sessionQueue` benutzt
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var options = CaptureOptions(frameRate: StreamSettings.defaultFrameRate)
    private var audioAllowed = false
    private var outputsAdded = false

    // Nur auf `queue` benutzt
    private var swapLR = false
    /// MS2109: Die „Mono“-Samples sind abwechselnd links/rechts (96 kHz mono = 48 kHz stereo)
    private var audioIsMS2109 = false
    private var pending: Float?
    private var monitorRate: Double?
    private var frameCount = 0
    private var lastStats = ProcessInfo.processInfo.systemUptime
    private var lastDebug = ProcessInfo.processInfo.systemUptime
    private var videoW = 0
    private var videoH = 0
    private var peakL: Float = 0
    private var peakR: Float = 0
    private var audioInfo = "no audio"
    private var recorder: Recorder?
    private var snapshotRequests: [SnapshotRequest] = []
    private var stream: StreamService?

    // MARK: Start / Stopp

    func start(options: CaptureOptions, completion: @escaping @MainActor (CaptureSetup) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { videoOK in
            AVCaptureDevice.requestAccess(for: .audio) { audioOK in
                self.sessionQueue.async {
                    guard videoOK else {
                        var setup = CaptureSetup()
                        setup.notes.append("No camera access – allow it in System Settings › Privacy & Security › Camera")
                        Self.onMain { completion(setup) }
                        return
                    }
                    self.audioAllowed = audioOK
                    let setup = self.apply(options)
                    self.startTimer()
                    Self.onMain { completion(setup) }
                }
            }
        }
    }

    /// Andere Geräte oder Bildrate übernehmen (z. B. nach Auswahl im Menü)
    func reconfigure(options: CaptureOptions, completion: @escaping @MainActor (CaptureSetup) -> Void) {
        sessionQueue.async {
            let setup = self.apply(options)
            Self.onMain { completion(setup) }
        }
    }

    /// Nur die Bildrate ändern – ohne die Geräte neu einzurichten, eine laufende Aufnahme geht weiter.
    /// Liefert die eingestellte Bildrate und ggf. einen Hinweis, wenn das Gerät die gewünschte nicht schafft.
    func setFrameRate(_ fps: Int, completion: @escaping @MainActor (Double?, String?) -> Void) {
        sessionQueue.async {
            self.options.frameRate = fps
            let choice = self.applyVideoFormat()
            var note: String?
            if let choice, choice.fps < Double(fps) - 0.5, let device = self.videoInput?.device {
                note = "“\(device.localizedName)” delivers at most \(Int(choice.fps.rounded())) fps at \(choice.width)×\(choice.height)"
            }
            let applied = choice?.fps
            let hint = note
            Self.onMain { completion(applied, hint) }
        }
    }

    func stop() {
        sessionQueue.sync {
            session.stopRunning()
        }
        monitor.stop()
    }

    func setSwap(_ on: Bool) {
        queue.async { self.swapLR = on }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.05, repeating: 0.05)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    // MARK: Geräte

    /// Alle Videogeräte: externe (Capture-Sticks, Kameras) und die eingebaute Kamera
    static func videoDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external, .builtInWideAngleCamera], mediaType: .video,
                                         position: .unspecified).devices
    }

    static func audioDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio,
                                         position: .unspecified).devices
    }

    /// MacroSilicon MS2109 (USB 534d:2109): Video heißt „USB Video“, Ton „USB Digital Audio“
    static func isMS2109Video(_ device: AVCaptureDevice) -> Bool {
        device.localizedName == "USB Video"
            || device.uniqueID.lowercased().hasSuffix("534d2109")
            || device.modelID.contains("VendorID_21325")
    }

    static func isMS2109Audio(_ device: AVCaptureDevice) -> Bool {
        let ids = (device.uniqueID + " " + device.modelID).lowercased()
        return device.localizedName.localizedCaseInsensitiveContains("USB Digital Audio")
            || ids.contains("macrosilicon") || ids.contains("534d")
    }

    /// Automatisch: der MS2109-Stick, sonst das erste externe Gerät (nie die eingebaute Kamera)
    static func automaticVideoDevice(in devices: [AVCaptureDevice]) -> AVCaptureDevice? {
        let external = devices.filter { $0.deviceType == .external }
        return external.first(where: isMS2109Video) ?? external.first
    }

    /// Automatisch passender Ton: gleicher USB-Anschluss oder gleicher Name wie das Videogerät,
    /// sonst (beim MS2109 oder ohne Videogerät) „USB Digital Audio“. Ein Mikrofon wird nie geraten.
    static func automaticAudioDevice(for video: AVCaptureDevice?, in devices: [AVCaptureDevice]) -> AVCaptureDevice? {
        if let video {
            if let location = usbLocation(of: video),
               let match = devices.first(where: { $0.uniqueID.lowercased().contains(location) }) {
                return match
            }
            if let match = devices.first(where: { $0.localizedName == video.localizedName }) { return match }
            if isMS2109Video(video) == false { return nil }
        }
        return devices.first(where: isMS2109Audio)
    }

    /// UVC-Geräte haben die uniqueID „0x<Location-ID><Vendor><Product>“, z. B. 0x1140000534d2109 → „1140000“
    private static func usbLocation(of device: AVCaptureDevice) -> String? {
        let id = device.uniqueID.lowercased()
        guard id.hasPrefix("0x"), id.count > 14 else { return nil }
        let location = String(id.dropFirst(2).dropLast(8))
        guard location.count >= 5, location.allSatisfy(\.isHexDigit) else { return nil }
        return location
    }

    /// Bestes Format: Auflösung bis 1080p zuerst, dann die gewünschte Bildrate, bei Gleichstand 420v
    /// (beim MS2109 der MJPEG-Modus; der unkomprimierte Modus schafft bei 1080p nur 5 fps).
    static func chooseFormat(_ device: AVCaptureDevice, frameRate: Int) -> FormatChoice? {
        let wanted = Double(frameRate)
        let nv12 = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        var best: (choice: FormatChoice, key: (Int, Int, Int))?
        for format in device.formats {
            let dim = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let area = Int(dim.width) * Int(dim.height)
            let fitsHD = dim.width <= 1920 && dim.height <= 1080
            let isNV12 = CMFormatDescriptionGetMediaSubType(format.formatDescription) == nv12
            for range in format.videoSupportedFrameRateRanges {
                let fps = min(range.maxFrameRate, wanted)
                guard fps > 0, fps >= range.minFrameRate - 0.01 else { continue }
                // Nur Werte innerhalb des Bereichs – ein ungültiger löst eine Exception aus
                let duration: CMTime
                if abs(range.maxFrameRate - fps) < 0.01 {
                    duration = range.minFrameDuration
                } else if abs(range.minFrameRate - fps) < 0.01 {
                    duration = range.maxFrameDuration
                } else {
                    duration = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
                }
                let key = (fitsHD ? area : -area, Int((fps * 100).rounded()), isNV12 ? 1 : 0)
                if let current = best, current.key >= key { continue }
                best = (FormatChoice(format: format, duration: duration, fps: fps,
                                     width: Int(dim.width), height: Int(dim.height)), key)
            }
        }
        return best?.choice
    }

    /// Richtet die Session neu ein (auf `sessionQueue`)
    private func apply(_ newOptions: CaptureOptions) -> CaptureSetup {
        options = newOptions
        var setup = CaptureSetup()

        let videoDevices = Self.videoDevices()
        var videoDevice: AVCaptureDevice?
        if let id = newOptions.videoDeviceID {
            videoDevice = videoDevices.first { $0.uniqueID == id }
            if videoDevice == nil { setup.notes.append("Selected video device not connected – using automatic") }
        }
        if videoDevice == nil { videoDevice = Self.automaticVideoDevice(in: videoDevices) }

        session.beginConfiguration()
        if let input = videoInput { session.removeInput(input) }
        if let input = audioInput { session.removeInput(input) }
        videoInput = nil
        audioInput = nil
        if outputsAdded == false {
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
            videoOutput.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
            audioOutput.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }
            outputsAdded = true
        }

        if let device = videoDevice {
            do {
                let input = try AVCaptureDeviceInput(device: device)
                if session.canAddInput(input) {
                    session.addInput(input)
                    videoInput = input
                } else {
                    setup.notes.append("Video: “\(device.localizedName)” can't be used")
                }
            } catch {
                setup.notes.append("Video: \(error.localizedDescription)")
            }
        } else {
            setup.notes.append("No capture device found")
        }

        if audioAllowed == false {
            setup.notes.append("No microphone access – audio off")
        } else if newOptions.audioDeviceID != CaptureOptions.noAudio {
            let audioDevices = Self.audioDevices()
            var audioDevice: AVCaptureDevice?
            if let id = newOptions.audioDeviceID {
                audioDevice = audioDevices.first { $0.uniqueID == id }
                if audioDevice == nil { setup.notes.append("Selected audio device not connected – using automatic") }
            }
            if audioDevice == nil { audioDevice = Self.automaticAudioDevice(for: videoInput?.device, in: audioDevices) }
            if let device = audioDevice {
                do {
                    let input = try AVCaptureDeviceInput(device: device)
                    if session.canAddInput(input) {
                        session.addInput(input)
                        audioInput = input
                    }
                } catch {
                    setup.notes.append("Audio: \(error.localizedDescription)")
                }
            } else if videoInput.map({ Self.isMS2109Video($0.device) }) ?? true {
                setup.notes.append("Audio device “USB Digital Audio” not found")
                debugLog("Audio devices found: \(audioDevices.map(\.localizedName).joined(separator: ", "))")
            } else {
                setup.notes.append("No audio device found for this source – choose one under Input")
            }
        }

        applyVideoFormat()
        session.commitConfiguration()
        if session.isRunning == false { session.startRunning() }
        // Beim Start setzt AVFoundation das Format gern zurück – danach erneut setzen.
        let choice = applyVideoFormat()

        let isMS2109 = audioInput.map { Self.isMS2109Audio($0.device) } ?? false
        queue.async {
            self.audioIsMS2109 = isMS2109
            self.pending = nil
        }

        if let device = videoInput?.device {
            setup.videoID = device.uniqueID
            setup.videoName = device.localizedName
            let d = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            let fps = 1 / CMTimeGetSeconds(device.activeVideoMinFrameDuration)
            setup.frameRate = fps.isFinite ? fps : nil
            debugLog("Device “\(device.localizedName)”, active format \(d.width)x\(d.height) @ \(String(format: "%.2f", fps)) fps")
            if let choice, choice.fps < Double(newOptions.frameRate) - 0.5 {
                setup.notes.append("“\(device.localizedName)” delivers at most \(Int(choice.fps.rounded())) fps "
                                   + "at \(choice.width)×\(choice.height)")
            }
        }
        if let device = audioInput?.device {
            setup.audioID = device.uniqueID
            setup.audioName = device.localizedName
        }
        return setup
    }

    @discardableResult
    private func applyVideoFormat() -> FormatChoice? {
        guard let device = videoInput?.device,
              let choice = Self.chooseFormat(device, frameRate: options.frameRate) else { return nil }
        do {
            try device.lockForConfiguration()
            device.activeFormat = choice.format
            device.activeVideoMinFrameDuration = choice.duration
            device.unlockForConfiguration()
        } catch {
            debugLog("Can't configure the device: \(error)")
        }
        return choice
    }

    // MARK: Stream im Netzwerk

    func startStreaming(accessList: NetworkAccessList, settings: StreamSettings,
                        completion: @escaping @MainActor (Result<StreamAddresses, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stream?.stop()
            // Zeitstempel der Capture-Daten beziehen sich auf diese Uhr
            let clock = self.session.synchronizationClock ?? CMClockGetHostTimeClock()
            let service = StreamService(clock: clock, accessList: accessList, settings: settings)
            service.onViewers = { [weak self] count in
                guard let callback = self?.onViewers else { return }
                Self.onMain { callback(count) }
            }
            service.onRejected = { [weak self] host in
                guard let callback = self?.onStreamRejected else { return }
                Self.onMain { callback(host) }
            }
            self.stream = service
            service.start { [weak self] result in
                if case .failure = result {
                    self?.queue.async {
                        guard let self, self.stream === service else { return }
                        service.stop()
                        self.stream = nil
                    }
                }
                Self.onMain { completion(result) }
            }
        }
    }

    func updateStreamAccess(_ accessList: NetworkAccessList) {
        queue.async { [weak self] in
            self?.stream?.setAccessList(accessList)
        }
    }

    func stopStreaming() {
        queue.async { [weak self] in
            self?.stream?.stop()
            self?.stream = nil
        }
    }

    // MARK: Aufnahme

    func startRecording(to url: URL, bitRate: Int, codec: VideoCodec, frameRate: Int,
                        completion: @escaping @MainActor (Error?) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let recorder = try Recorder(url: url,
                                            width: self.videoW > 0 ? self.videoW : 1920,
                                            height: self.videoH > 0 ? self.videoH : 1080,
                                            bitRate: bitRate, codec: codec, frameRate: frameRate)
                recorder.onFailure = { [weak self, weak recorder] reason in
                    guard let self, let recorder, self.recorder === recorder else { return }
                    self.recorder = nil
                    let url = recorder.url
                    if let callback = self.onRecordingFailed { Self.onMain { callback(url, reason) } }
                }
                self.recorder = recorder
                Self.onMain { completion(nil) }
            } catch {
                Self.onMain { completion(error) }
            }
        }
    }

    /// Beendet die Aufnahme; liefert die Datei und ihre Länge in Sekunden
    func stopRecording(completion: @escaping @MainActor (URL?, Double) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let recorder = self.recorder else {
                Self.onMain { completion(nil, 0) }
                return
            }
            self.recorder = nil
            let duration = recorder.duration
            recorder.finish { url in Self.onMain { completion(url, duration) } }
        }
    }

    // MARK: Standbild

    /// Liefert das nächste Videobild als Standbild – oder nil, wenn binnen 1 s kein Bild kommt.
    func snapshot(completion: @escaping @MainActor (Snapshot?) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.snapshotRequests.append(SnapshotRequest(time: ProcessInfo.processInfo.systemUptime, done: completion))
        }
    }

    /// Wandelt das NV12-Bild in sRGB und kodiert es als PNG – auf eigener Queue, damit die Aufnahme nicht stockt.
    private func makeSnapshot(from pixelBuffer: CVPixelBuffer, for requests: [SnapshotRequest]) {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let context = ciContext
        snapshotQueue.async {
            let result: Snapshot?
            if let srgb = CGColorSpace(name: CGColorSpace.sRGB),
               let cgImage = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: srgb),
               let png = Self.pngData(cgImage) {
                result = Snapshot(image: cgImage, png: png)
            } else {
                debugLog("Couldn't create the still image")
                result = nil
            }
            for request in requests {
                let done = request.done
                Self.onMain { done(result) }
            }
        }
    }

    private static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func onMain(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
    }

    // MARK: Daten vom Gerät

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput {
            frameCount += 1
            recorder?.appendVideo(sampleBuffer)
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            videoW = CVPixelBufferGetWidth(pixelBuffer)
            videoH = CVPixelBufferGetHeight(pixelBuffer)
            stream?.encoder.encodeVideo(pixelBuffer, hostTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            if snapshotRequests.isEmpty == false {
                let requests = snapshotRequests
                snapshotRequests.removeAll()
                makeSnapshot(from: pixelBuffer, for: requests)
            }
        } else if output === audioOutput {
            handleAudio(sampleBuffer)
        }
    }

    /// Alle Kanäle als Float, verschachtelt (L R L R … bzw. bei Mono einfach hintereinander)
    private static func readSamples(_ sampleBuffer: CMSampleBuffer, asbd: AudioStreamBasicDescription) -> [Float]? {
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let bigEndian = (asbd.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0
        let nonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let channels = Int(asbd.mChannelsPerFrame)
        guard (isFloat && asbd.mBitsPerChannel == 32) || (isFloat == false && asbd.mBitsPerChannel == 16) else { return nil }

        func convert(_ raw: UnsafeRawBufferPointer) -> [Float] {
            if isFloat {
                return Array(raw.bindMemory(to: Float.self))
            }
            return raw.bindMemory(to: Int16.self).map { Float(bigEndian ? Int16(bigEndian: $0) : $0) / 32768 }
        }

        if nonInterleaved == false || channels == 1 {
            // Ein Puffer mit allen Kanälen
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
            let length = CMBlockBufferGetDataLength(block)
            var bytes = [UInt8](repeating: 0, count: length)
            guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &bytes) == kCMBlockBufferNoErr else {
                return nil
            }
            let usable = length - length % (isFloat ? 4 : 2)
            return bytes.withUnsafeBytes { convert(UnsafeRawBufferPointer(rebasing: $0[0..<usable])) }
        }

        // Ein Puffer pro Kanal: verschachteln
        var needed = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: &needed, bufferListOut: nil,
                                                                bufferListSize: 0, blockBufferAllocator: nil,
                                                                blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard needed > 0 else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var retained: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: list,
                                                                      bufferListSize: needed, blockBufferAllocator: nil,
                                                                      blockBufferMemoryAllocator: nil,
                                                                      flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                                                                      blockBufferOut: &retained) == noErr else { return nil }
        let planes = UnsafeMutableAudioBufferListPointer(list).compactMap { buffer -> [Float]? in
            guard let data = buffer.mData else { return nil }
            return convert(UnsafeRawBufferPointer(start: data, count: Int(buffer.mDataByteSize)))
        }
        guard let frames = planes.map(\.count).min(), frames > 0 else { return nil }
        var out = [Float](repeating: 0, count: frames * planes.count)
        for (channel, plane) in planes.enumerated() {
            for index in 0..<frames { out[index * planes.count + channel] = plane[index] }
        }
        return out
    }

    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee,
              asbd.mChannelsPerFrame >= 1,
              var samples = Self.readSamples(sampleBuffer, asbd: asbd) else { return }
        let channels = Int(asbd.mChannelsPerFrame)

        var pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let rate: Double
        if channels == 1 && (audioIsMS2109 || asbd.mSampleRate >= 88_200) {
            // MS2109: Die „Mono“-Samples sind in Wahrheit abwechselnd links/rechts.
            if let p = pending {
                samples.insert(p, at: 0)
                pts = CMTimeSubtract(pts, CMTime(value: 1, timescale: CMTimeScale(asbd.mSampleRate)))
                pending = nil
            }
            if samples.count % 2 == 1 { pending = samples.removeLast() }
            rate = asbd.mSampleRate / 2
        } else if channels == 1 {
            // Echtes Mono: auf beide Kanäle
            var stereo = [Float](repeating: 0, count: samples.count * 2)
            for (index, sample) in samples.enumerated() {
                stereo[index * 2] = sample
                stereo[index * 2 + 1] = sample
            }
            samples = stereo
            rate = asbd.mSampleRate
        } else if channels > 2 {
            // Mehrkanal: die ersten beiden Kanäle
            let frames = samples.count / channels
            var stereo = [Float](repeating: 0, count: frames * 2)
            for index in 0..<frames {
                stereo[index * 2] = samples[index * channels]
                stereo[index * 2 + 1] = samples[index * channels + 1]
            }
            samples = stereo
            rate = asbd.mSampleRate
        } else {
            rate = asbd.mSampleRate
        }
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        audioInfo = "\(Int(asbd.mSampleRate)) Hz, \(channels) ch, \(isFloat ? "Float" : "Int") \(asbd.mBitsPerChannel) bit → \(Int(rate)) Hz stereo"
        guard samples.count >= 2 else { return }

        if swapLR {
            var i = 0
            while i + 1 < samples.count {
                samples.swapAt(i, i + 1)
                i += 2
            }
        }
        var i = 0
        while i + 1 < samples.count {
            peakL = max(peakL, abs(samples[i]))
            peakR = max(peakR, abs(samples[i + 1]))
            i += 2
        }
        if monitorRate != rate {
            monitor.start(sampleRate: rate)
            monitorRate = rate
        }
        monitor.push(samples)
        recorder?.appendAudio(samples, rate: rate, pts: pts)
        stream?.encoder.encodeAudio(samples, sampleRate: rate, hostTime: pts)
    }

    // Alle 50 ms: Pegel an die Oberfläche, jede Sekunde Bildrate, alle 10 s Diagnose.
    private func tick() {
        let l = peakL, r = peakR
        peakL = 0
        peakR = 0
        if let levels = onLevels { Self.onMain { levels(l, r) } }

        let now = ProcessInfo.processInfo.systemUptime
        if let first = snapshotRequests.first, now - first.time > 1 {
            // Kein Signal → wartende Standbild-Anfragen abbrechen
            let requests = snapshotRequests
            snapshotRequests.removeAll()
            for request in requests {
                let done = request.done
                Self.onMain { done(nil) }
            }
        }
        if now - lastStats >= 1 {
            let fps = Double(frameCount) / (now - lastStats)
            frameCount = 0
            lastStats = now
            let w = videoW, h = videoH
            if let stats = onStats { Self.onMain { stats(fps, w, h) } }
            if now - lastDebug >= 10 {
                lastDebug = now
                debugLog("Video \(w)x\(h) @ \(String(format: "%.1f", fps)) fps | Audio: \(audioInfo) | Buffer \(monitor.bufferedMilliseconds) ms")
            }
        }
    }
}
