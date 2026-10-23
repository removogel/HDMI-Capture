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

struct VideoMode {
    let device: AVCaptureDevice
    let format: AVCaptureDevice.Format?
    let range: AVFrameRateRange?
}

/// Ein Standbild aus dem Videostrom in voller Auflösung, als Bild und fertig kodiertes PNG.
struct Snapshot {
    let image: CGImage
    let png: Data
}

/// Holt Bild und Ton von der Capture-Karte, wählt den flüssigen MJPEG-Modus (420v)
/// und deutet den Ton richtig: Der MS2109 meldet 96 kHz mono, liefert aber 48 kHz stereo.
final class CaptureEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let monitor = AudioMonitor()

    var onLevels: (@MainActor (Float, Float) -> Void)?
    var onStats: (@MainActor (Double, Int, Int) -> Void)?

    private let queue = DispatchQueue(label: "local.hdmicapture.capture", qos: .userInteractive)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var mode: VideoMode?
    private var timer: DispatchSourceTimer?
    private let snapshotQueue = DispatchQueue(label: "local.hdmicapture.snapshot", qos: .userInitiated)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    private struct SnapshotRequest {
        let time: TimeInterval
        let done: @MainActor (Snapshot?) -> Void
    }

    // Nur auf `queue` benutzt
    private var swapLR = false
    private var pending: Float?
    private var frameCount = 0
    private var lastStats = ProcessInfo.processInfo.systemUptime
    private var lastDebug = ProcessInfo.processInfo.systemUptime
    private var videoW = 0
    private var videoH = 0
    private var peakL: Float = 0
    private var peakR: Float = 0
    private var audioInfo = "kein Ton"
    private var recorder: Recorder?
    private var snapshotRequests: [SnapshotRequest] = []

    // MARK: Start / Stopp

    func start(completion: @escaping @MainActor (String?) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { videoOK in
            AVCaptureDevice.requestAccess(for: .audio) { audioOK in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if videoOK == false {
                            completion("Kein Kamerazugriff – in Systemeinstellungen › Datenschutz & Sicherheit › Kamera erlauben")
                            return
                        }
                        completion(self.configure(audioAllowed: audioOK))
                    }
                }
            }
        }
    }

    func stop() {
        session.stopRunning()
        monitor.stop()
    }

    func setSwap(_ on: Bool) {
        queue.async { self.swapLR = on }
    }

    private func configure(audioAllowed: Bool) -> String? {
        guard let m = Self.findVideoMode() else { return "Kein Capture-Gerät gefunden" }
        mode = m
        var note: String?

        session.beginConfiguration()
        do {
            let input = try AVCaptureDeviceInput(device: m.device)
            if session.canAddInput(input) { session.addInput(input) }
        } catch {
            session.commitConfiguration()
            return "Video: \(error.localizedDescription)"
        }
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        if audioAllowed == false {
            note = "Kein Mikrofonzugriff – Ton aus"
        } else if let audioDevice = Self.findAudioDevice() {
            do {
                let input = try AVCaptureDeviceInput(device: audioDevice)
                if session.canAddInput(input) { session.addInput(input) }
                audioOutput.setSampleBufferDelegate(self, queue: queue)
                if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }
            } catch {
                note = "Ton: \(error.localizedDescription)"
            }
        } else {
            note = "Audiogerät „USB Digital Audio“ nicht gefunden"
            let names = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio,
                                                         position: .unspecified).devices.map(\.localizedName)
            debugLog("Gefundene Audiogeräte: \(names.joined(separator: ", "))")
        }
        applyFormat()
        session.commitConfiguration()

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.05, repeating: 0.05)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t

        queue.async { [weak self] in
            guard let self else { return }
            self.session.startRunning()
            // Beim Start setzt AVFoundation das Format gern zurück – danach erneut setzen.
            self.applyFormat()
            let d = CMVideoFormatDescriptionGetDimensions(m.device.activeFormat.formatDescription)
            let fps = 1 / CMTimeGetSeconds(m.device.activeVideoMinFrameDuration)
            debugLog("Gerät „\(m.device.localizedName)“, aktiv \(d.width)x\(d.height) @ \(String(format: "%.2f", fps)) fps")
        }
        return note
    }

    static func findVideoMode() -> VideoMode? {
        let all = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified).devices
        let devices = all.filter { $0.localizedName == "USB Video" } + all.filter { $0.localizedName != "USB Video" }
        let nv12 = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        for device in devices {
            for format in device.formats {
                let dim = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                guard CMFormatDescriptionGetMediaSubType(format.formatDescription) == nv12,
                      dim.width == 1920, dim.height == 1080 else { continue }
                if let range = format.videoSupportedFrameRateRanges.first(where: { abs($0.maxFrameRate - 30) < 0.01 }) {
                    return VideoMode(device: device, format: format, range: range)
                }
            }
        }
        if let device = devices.first { return VideoMode(device: device, format: nil, range: nil) }
        return nil
    }

    static func findAudioDevice() -> AVCaptureDevice? {
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
        return devices.first(where: { $0.localizedName == "USB Digital Audio" })
            ?? devices.first(where: { $0.localizedName.localizedCaseInsensitiveContains("USB Digital Audio") })
    }

    private func applyFormat() {
        guard let m = mode, let format = m.format else { return }
        do {
            try m.device.lockForConfiguration()
            m.device.activeFormat = format
            if let range = m.range { m.device.activeVideoMinFrameDuration = range.minFrameDuration }
            m.device.unlockForConfiguration()
        } catch {
            debugLog("Gerät nicht konfigurierbar: \(error)")
        }
    }

    // MARK: Aufnahme

    func startRecording(to url: URL, completion: @escaping @MainActor (Error?) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                self.recorder = try Recorder(url: url,
                                             width: self.videoW > 0 ? self.videoW : 1920,
                                             height: self.videoH > 0 ? self.videoH : 1080)
                Self.onMain { completion(nil) }
            } catch {
                Self.onMain { completion(error) }
            }
        }
    }

    func stopRecording(completion: @escaping @MainActor (URL?) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let recorder = self.recorder else {
                Self.onMain { completion(nil) }
                return
            }
            self.recorder = nil
            recorder.finish { url in Self.onMain { completion(url) } }
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
                debugLog("Standbild konnte nicht erzeugt werden")
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

    // MARK: Daten von der Karte

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput {
            frameCount += 1
            recorder?.appendVideo(sampleBuffer)
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            videoW = CVPixelBufferGetWidth(pixelBuffer)
            videoH = CVPixelBufferGetHeight(pixelBuffer)
            if snapshotRequests.isEmpty == false {
                let requests = snapshotRequests
                snapshotRequests.removeAll()
                makeSnapshot(from: pixelBuffer, for: requests)
            }
        } else if output === audioOutput {
            handleAudio(sampleBuffer)
        }
    }

    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee,
              let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let channels = Int(asbd.mChannelsPerFrame)
        guard channels == 1 || channels == 2 else { return }
        let length = CMBlockBufferGetDataLength(block)
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let bigEndian = (asbd.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0

        var samples: [Float]
        if isFloat && asbd.mBitsPerChannel == 32 {
            samples = [Float](repeating: 0, count: length / 4)
            let bytes = samples.count * 4
            let status = samples.withUnsafeMutableBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: base)
            }
            guard status == noErr else { return }
        } else if isFloat == false && asbd.mBitsPerChannel == 16 {
            var ints = [Int16](repeating: 0, count: length / 2)
            let bytes = ints.count * 2
            let status = ints.withUnsafeMutableBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: base)
            }
            guard status == noErr else { return }
            samples = ints.map { Float(bigEndian ? Int16(bigEndian: $0) : $0) / 32768 }
        } else {
            return
        }

        var pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let rate: Double
        if channels == 1 {
            // MS2109: Die „Mono“-Samples sind in Wahrheit abwechselnd links/rechts.
            if let p = pending {
                samples.insert(p, at: 0)
                pts = CMTimeSubtract(pts, CMTime(value: 1, timescale: CMTimeScale(asbd.mSampleRate)))
                pending = nil
            }
            if samples.count % 2 == 1 { pending = samples.removeLast() }
            rate = asbd.mSampleRate / 2
        } else {
            rate = asbd.mSampleRate
        }
        audioInfo = "\(Int(asbd.mSampleRate)) Hz, \(channels) Kanal, \(isFloat ? "Float" : "Int") \(asbd.mBitsPerChannel) Bit → \(Int(rate)) Hz stereo"
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
        if monitor.isRunning == false { monitor.start(sampleRate: rate) }
        monitor.push(samples)
        recorder?.appendAudio(samples, rate: rate, pts: pts)
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
                debugLog("Video \(w)x\(h) @ \(String(format: "%.1f", fps)) fps | Ton: \(audioInfo) | Puffer \(monitor.bufferedMilliseconds) ms")
            }
        }
    }
}
