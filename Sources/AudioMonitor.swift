import AVFoundation
import os

/// Spielt den Stereoton der Karte mit kurzer Verzögerung über die Standard-Ausgabe ab.
/// Ringpuffer zwischen Capture-Queue (schreibt) und Audio-Thread (liest).
final class AudioMonitor {
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private var observer: NSObjectProtocol?

    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private let capacity = 96_000                 // Frames
    private let data: UnsafeMutablePointer<Float> // stereo, verschachtelt
    private var readPos = 0
    private var available = 0
    private var primed = false
    private var target = 2_400                    // Ziel-Puffer: 50 ms
    private var maxLatency = 12_000               // darüber wird auf das Ziel gekürzt
    private var sampleRate: Double = 48_000
    private var storedVolume: Float = 1

    private(set) var isRunning = false

    init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        data = .allocate(capacity: capacity * 2)
        data.initialize(repeating: 0, count: capacity * 2)
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        data.deallocate()
        lock.deallocate()
    }

    var volume: Float {
        get { storedVolume }
        set {
            storedVolume = newValue
            if isRunning { engine.mainMixerNode.outputVolume = newValue }
        }
    }

    var bufferedMilliseconds: Int {
        os_unfair_lock_lock(lock)
        let frames = available
        os_unfair_lock_unlock(lock)
        return Int(Double(frames) / sampleRate * 1000)
    }

    func start(sampleRate: Double) {
        guard source == nil, let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return }
        self.sampleRate = sampleRate
        target = Int(sampleRate * 0.05)
        maxLatency = Int(sampleRate * 0.25)

        let node = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, bufferList in
            self.render(Int(frameCount), bufferList)
            return noErr
        }
        source = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = storedVolume
        engine.prepare()
        do {
            try engine.start()
            isRunning = true
        } catch {
            debugLog("Audio-Ausgabe startet nicht: \(error)")
        }
        // Ausgabegerät gewechselt (z. B. Kopfhörer) → Engine neu starten
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            guard let self else { return }
            do { try self.engine.start() } catch { debugLog("Audio-Neustart fehlgeschlagen: \(error)") }
        }
    }

    func stop() {
        engine.stop()
        isRunning = false
    }

    /// Nimmt verschachtelte Stereo-Samples (L R L R …) entgegen.
    func push(_ frames: [Float]) {
        let n = frames.count / 2
        guard isRunning, n > 0, n < capacity - maxLatency else { return }
        os_unfair_lock_lock(lock)
        var w = (readPos + available) % capacity
        for i in 0..<n {
            data[w * 2] = frames[i * 2]
            data[w * 2 + 1] = frames[i * 2 + 1]
            w += 1
            if w == capacity { w = 0 }
        }
        available += n
        if available > maxLatency {
            // Verzögerung zu groß geworden (Start oder Taktabweichung) → auf Ziel kürzen
            let drop = available - target
            readPos = (readPos + drop) % capacity
            available -= drop
        }
        os_unfair_lock_unlock(lock)
    }

    private func render(_ n: Int, _ bufferList: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        guard buffers.count >= 2,
              let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
              let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return }
        var produced = 0
        os_unfair_lock_lock(lock)
        if primed == false && available >= target { primed = true }
        if primed {
            let take = min(n, available)
            for i in 0..<take {
                let idx = ((readPos + i) % capacity) * 2
                left[i] = data[idx]
                right[i] = data[idx + 1]
            }
            readPos = (readPos + take) % capacity
            available -= take
            if take < n { primed = false }   // Unterlauf → erst wieder voll werden lassen
            produced = take
        }
        os_unfair_lock_unlock(lock)
        if produced < n {
            for i in produced..<n {
                left[i] = 0
                right[i] = 0
            }
        }
    }
}
