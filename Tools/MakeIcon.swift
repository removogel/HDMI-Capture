import AppKit

// Zeichnet das App-Icon (1024 × 1024 PNG): dunkles Quadrat, HDMI-Buchse, roter Aufnahmepunkt.
let size = 1024
guard CommandLine.arguments.count > 1,
      let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let s = CGFloat(size)
let inset: CGFloat = 100
let background = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset),
                              xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(calibratedRed: 0.17, green: 0.19, blue: 0.26, alpha: 1),
           ending: NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.09, alpha: 1))?.draw(in: background, angle: -90)

// HDMI-Buchse
let cx = s / 2
let cy = s / 2 + 40
let topWidth: CGFloat = 480
let bottomWidth: CGFloat = 330
let height: CGFloat = 180
let port = NSBezierPath()
port.move(to: NSPoint(x: cx - topWidth / 2, y: cy + height / 2))
port.line(to: NSPoint(x: cx + topWidth / 2, y: cy + height / 2))
port.line(to: NSPoint(x: cx + topWidth / 2, y: cy))
port.line(to: NSPoint(x: cx + bottomWidth / 2, y: cy - height / 2))
port.line(to: NSPoint(x: cx - bottomWidth / 2, y: cy - height / 2))
port.line(to: NSPoint(x: cx - topWidth / 2, y: cy))
port.close()
port.lineJoinStyle = .round
port.lineWidth = 36
NSColor.white.setStroke()
port.stroke()

let contacts = NSBezierPath(roundedRect: NSRect(x: cx - 165, y: cy - 2, width: 330, height: 42), xRadius: 14, yRadius: 14)
NSColor(white: 1, alpha: 0.85).setFill()
contacts.fill()

// Aufnahmepunkt
let dot = NSBezierPath(ovalIn: NSRect(x: cx - 60, y: inset + 105, width: 120, height: 120))
NSColor(calibratedRed: 1.0, green: 0.23, blue: 0.19, alpha: 1).setFill()
dot.fill()

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
do {
    try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
} catch {
    exit(1)
}
