import AppKit
import AVFoundation

/// Zeigt das Live-Bild (AVCaptureVideoPreviewLayer) und meldet Mausbewegungen.
final class PreviewView: NSView {
    let previewLayer: AVCaptureVideoPreviewLayer
    var onActivity: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        previewLayer.videoGravity = .resizeAspect
        previewLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) { fatalError("nicht unterstützt") }

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) { onActivity?() }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() } else { onActivity?() }
    }

    // Esc beendet den Vollbildmodus
    override func cancelOperation(_ sender: Any?) {
        if let window, window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
    }
}

/// Zwei waagerechte Pegelbalken (oben links, unten rechts), Skala −60 … 0 dBFS.
final class LevelMeterView: NSView {
    var levels: (Float, Float) = (0, 0) {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let gap: CGFloat = 2
        let barHeight = (bounds.height - gap) / 2
        for (index, value) in [levels.0, levels.1].enumerated() {
            let y = index == 0 ? barHeight + gap : 0
            NSColor(white: 1, alpha: 0.15).setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: y, width: bounds.width, height: barHeight), xRadius: 1.5, yRadius: 1.5).fill()
            let db = 20 * log10(max(Double(value), 0.00001))
            let fraction = CGFloat(min(1, max(0, (db + 60) / 60)))
            guard fraction > 0 else { continue }
            let color: NSColor = db > -3 ? .systemRed : (db > -12 ? .systemYellow : .systemGreen)
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: y, width: bounds.width * fraction, height: barHeight), xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}
