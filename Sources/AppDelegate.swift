import AppKit
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private let engine = CaptureEngine()
    private let defaults = UserDefaults.standard

    private var window: NSWindow!
    private var preview: PreviewView!
    private let controls = NSVisualEffectView()
    private let statusPill = NSVisualEffectView()
    private let statusLabel = NSTextField(labelWithString: "Starte …")
    private let recordButton = NSButton(title: "Aufnahme", target: nil, action: nil)
    private let swapBox = NSButton(checkboxWithTitle: "L/R tauschen", target: nil, action: nil)
    private let pinBox = NSButton(checkboxWithTitle: "Immer oben", target: nil, action: nil)
    private let volumeSlider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let meter = LevelMeterView()
    private let fullscreenButton = NSButton(title: "", target: nil, action: nil)
    private let snapshotButton = NSButton(title: "", target: nil, action: nil)
    private let shutter = ShutterView(frame: .zero)

    private var hideTimer: Timer?
    private var recTimer: Timer?
    private var recStart: Date?
    private var isRecording = false
    private var modeText = "Warte auf Bild …"
    private var flashText: String?
    private var flashID = 0
    private var shownLevels: (Float, Float) = (0, 0)
    private var activity: NSObjectProtocol?

    // MARK: - App-Lebenszyklus

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: ["volume": 1.0, "swapChannels": false, "alwaysOnTop": false])
        buildMenu()
        buildWindow()

        engine.onLevels = { [weak self] l, r in self?.updateLevels(l, r) }
        engine.onStats = { [weak self] fps, w, h in self?.updateStats(fps: fps, width: w, height: h) }
        engine.setSwap(defaults.bool(forKey: "swapChannels"))
        engine.monitor.volume = defaults.float(forKey: "volume")
        engine.start { [weak self] message in
            if let message { self?.flash(message, seconds: 10) }
        }

        activity = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated],
                                                         reason: "Live-Vorschau der Capture-Karte")
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(preview)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard isRecording else { return .terminateNow }
        // Laufende Aufnahme erst sauber abschließen
        engine.stopRecording { _ in NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stop()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }

    // MARK: - Fenster

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "HDMI Capture"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        window.minSize = NSSize(width: 800, height: 450)
        window.collectionBehavior = [.fullScreenPrimary]
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("HDMICaptureWindow")
        window.level = defaults.bool(forKey: "alwaysOnTop") ? .floating : .normal

        let content = NSView()
        window.contentView = content

        let preview = PreviewView(session: engine.session)
        preview.onActivity = { [weak self] in self?.showControls() }
        preview.onDoubleClick = { [weak self] in self?.window.toggleFullScreen(nil) }
        self.preview = preview

        recordButton.target = self
        recordButton.action = #selector(toggleRecording(_:))
        recordButton.imagePosition = .imageLeading
        recordButton.contentTintColor = .systemRed
        snapshotButton.target = self
        snapshotButton.action = #selector(takeSnapshot(_:))
        snapshotButton.image = NSImage(systemSymbolName: "camera", accessibilityDescription: "Bildschirmfoto")
        snapshotButton.imagePosition = .imageOnly
        snapshotButton.toolTip = "Bildschirmfoto sichern (⌘S)"
        swapBox.target = self
        swapBox.action = #selector(toggleSwap(_:))
        swapBox.state = defaults.bool(forKey: "swapChannels") ? .on : .off
        pinBox.target = self
        pinBox.action = #selector(togglePin(_:))
        pinBox.state = defaults.bool(forKey: "alwaysOnTop") ? .on : .off
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged(_:))
        volumeSlider.floatValue = defaults.float(forKey: "volume")
        volumeSlider.controlSize = .small
        fullscreenButton.target = self
        fullscreenButton.action = #selector(toggleFullscreen(_:))
        fullscreenButton.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Vollbild")
        fullscreenButton.imagePosition = .imageOnly
        let speaker = NSImageView()
        speaker.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Lautstärke")
        speaker.contentTintColor = .secondaryLabelColor
        meter.toolTip = "Pegel links / rechts"

        let stack = NSStackView(views: [recordButton, snapshotButton, Self.divider(), swapBox, speaker, volumeSlider, meter,
                                        Self.divider(), pinBox, fullscreenButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        Self.style(controls, radius: 12)
        controls.addSubview(stack)

        statusLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .white
        Self.style(statusPill, radius: 8)
        statusPill.addSubview(statusLabel)

        for view in [preview, shutter, controls, statusPill, stack, statusLabel, meter, volumeSlider] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        content.addSubview(preview)
        content.addSubview(shutter)
        content.addSubview(controls)
        content.addSubview(statusPill)

        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            preview.topAnchor.constraint(equalTo: content.topAnchor),
            preview.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            shutter.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            shutter.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            shutter.topAnchor.constraint(equalTo: content.topAnchor),
            shutter.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
            stack.topAnchor.constraint(equalTo: controls.topAnchor),
            stack.bottomAnchor.constraint(equalTo: controls.bottomAnchor),
            controls.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            controls.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),

            statusLabel.leadingAnchor.constraint(equalTo: statusPill.leadingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(equalTo: statusPill.trailingAnchor, constant: -10),
            statusLabel.topAnchor.constraint(equalTo: statusPill.topAnchor, constant: 5),
            statusLabel.bottomAnchor.constraint(equalTo: statusPill.bottomAnchor, constant: -5),
            statusPill.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            statusPill.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor, constant: 8),

            volumeSlider.widthAnchor.constraint(equalToConstant: 100),
            meter.widthAnchor.constraint(equalToConstant: 80),
            meter.heightAnchor.constraint(equalToConstant: 12),
        ])
        updateRecordUI()
    }

    private static func style(_ view: NSVisualEffectView, radius: CGFloat) {
        view.material = .hudWindow
        view.blendingMode = .withinWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = radius
        view.layer?.masksToBounds = true
        view.appearance = NSAppearance(named: .darkAqua)
    }

    private static func divider() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 1).isActive = true
        box.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return box
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        fullscreenButton.image = NSImage(systemSymbolName: "arrow.down.right.and.arrow.up.left", accessibilityDescription: "Vollbild beenden")
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        fullscreenButton.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Vollbild")
        window.level = defaults.bool(forKey: "alwaysOnTop") ? .floating : .normal
    }

    // MARK: - Bedienleiste ein-/ausblenden

    private func showControls() {
        hideTimer?.invalidate()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            controls.animator().alphaValue = 1
            statusPill.animator().alphaValue = 1
        }
        hideTimer = Timer.scheduledTimer(timeInterval: 3, target: self, selector: #selector(hideControlsIfIdle),
                                         userInfo: nil, repeats: false)
    }

    @objc private func hideControlsIfIdle() {
        let mouse = controls.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if controls.bounds.contains(mouse) {
            showControls()
            return
        }
        let keepStatus = isRecording || flashText != nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.4
            controls.animator().alphaValue = 0
            if keepStatus == false { statusPill.animator().alphaValue = 0 }
        }
        if window.styleMask.contains(.fullScreen) { NSCursor.setHiddenUntilMouseMoves(true) }
    }

    // MARK: - Anzeige

    private func updateStatus() {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let text = NSMutableAttributedString()
        if isRecording, let start = recStart {
            let t = Int(Date().timeIntervalSince(start))
            text.append(NSAttributedString(string: String(format: "● REC %02d:%02d:%02d   ", t / 3600, (t / 60) % 60, t % 60),
                                           attributes: [.foregroundColor: NSColor.systemRed, .font: font]))
        }
        text.append(NSAttributedString(string: flashText ?? modeText,
                                       attributes: [.foregroundColor: NSColor.white, .font: font]))
        statusLabel.attributedStringValue = text
    }

    private func updateStats(fps: Double, width: Int, height: Int) {
        modeText = fps < 1 ? "Kein Bild" : "\(width)×\(height) · \(Int(fps.rounded())) fps"
        updateStatus()
    }

    private func updateLevels(_ l: Float, _ r: Float) {
        shownLevels = (max(l, shownLevels.0 * 0.85), max(r, shownLevels.1 * 0.85))
        meter.levels = shownLevels
    }

    private func flash(_ text: String, seconds: Double = 5) {
        flashText = text
        flashID += 1
        let id = flashID
        updateStatus()
        showControls()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, self.flashID == id else { return }
            self.flashText = nil
            self.updateStatus()
        }
    }

    private func updateRecordUI() {
        recordButton.title = isRecording ? "Stopp" : "Aufnahme"
        recordButton.image = NSImage(systemSymbolName: isRecording ? "stop.circle.fill" : "record.circle",
                                     accessibilityDescription: nil)
        updateStatus()
        showControls()
    }

    // MARK: - Aktionen

    @objc func toggleRecording(_ sender: Any?) {
        recordButton.isEnabled = false
        if isRecording {
            engine.stopRecording { [weak self] url in
                guard let self else { return }
                self.isRecording = false
                self.recStart = nil
                self.recTimer?.invalidate()
                self.recTimer = nil
                self.recordButton.isEnabled = true
                self.updateRecordUI()
                if let url {
                    self.flash("Gespeichert: \(url.lastPathComponent)")
                } else {
                    self.flash("Aufnahme fehlgeschlagen")
                }
            }
        } else {
            let url: URL
            do {
                url = try Self.newFileURL(in: Self.recordingsFolder(), ext: "mp4")
            } catch {
                flash("Ordner „Filme“ nicht beschreibbar")
                recordButton.isEnabled = true
                return
            }
            engine.startRecording(to: url) { [weak self] error in
                guard let self else { return }
                self.recordButton.isEnabled = true
                if let error {
                    self.flash("Aufnahme nicht möglich: \(error.localizedDescription)")
                    return
                }
                self.isRecording = true
                self.recStart = Date()
                self.recTimer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(self.recTick),
                                                     userInfo: nil, repeats: true)
                self.updateRecordUI()
            }
        }
    }

    @objc private func recTick() { updateStatus() }

    @objc func showRecordings(_ sender: Any?) {
        if let folder = try? Self.recordingsFolder() { NSWorkspace.shared.open(folder) }
    }

    @objc func showSnapshots(_ sender: Any?) {
        if let folder = try? Self.snapshotsFolder() { NSWorkspace.shared.open(folder) }
    }

    @objc func takeSnapshot(_ sender: Any?) {
        engine.snapshot { [weak self] snapshot in
            guard let self else { return }
            guard let snapshot else {
                self.flash("Kein Bild für ein Bildschirmfoto")
                return
            }
            self.shutter.flash()
            do {
                let url = try Self.newFileURL(in: Self.snapshotsFolder(), ext: "png")
                try snapshot.png.write(to: url)
                self.flash("Bildschirmfoto: \(url.lastPathComponent)")
            } catch {
                self.flash("Bildschirmfoto nicht gespeichert: \(error.localizedDescription)")
            }
        }
    }

    @objc func copySnapshot(_ sender: Any?) {
        engine.snapshot { [weak self] snapshot in
            guard let self else { return }
            guard let snapshot else {
                self.flash("Kein Bild zum Kopieren")
                return
            }
            self.shutter.flash()
            let item = NSPasteboardItem()
            item.setData(snapshot.png, forType: .png)
            if let tiff = NSImage(cgImage: snapshot.image, size: .zero).tiffRepresentation {
                item.setData(tiff, forType: .tiff)
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([item])
            self.flash("Bild in die Zwischenablage kopiert")
        }
    }

    @objc func toggleSwap(_ sender: Any?) {
        let on = defaults.bool(forKey: "swapChannels") == false
        defaults.set(on, forKey: "swapChannels")
        swapBox.state = on ? .on : .off
        engine.setSwap(on)
    }

    @objc func togglePin(_ sender: Any?) {
        let on = defaults.bool(forKey: "alwaysOnTop") == false
        defaults.set(on, forKey: "alwaysOnTop")
        pinBox.state = on ? .on : .off
        window.level = on ? .floating : .normal
    }

    @objc func toggleFullscreen(_ sender: Any?) { window.toggleFullScreen(nil) }

    @objc func volumeChanged(_ sender: NSSlider) { setVolume(sender.floatValue) }
    @objc func volumeUp(_ sender: Any?) { setVolume(min(1, defaults.float(forKey: "volume") + 0.1)) }
    @objc func volumeDown(_ sender: Any?) { setVolume(max(0, defaults.float(forKey: "volume") - 0.1)) }

    private func setVolume(_ value: Float) {
        defaults.set(value, forKey: "volume")
        volumeSlider.floatValue = value
        engine.monitor.volume = value
        showControls()
    }

    // MARK: - Dateien

    /// Unterordner „HDMI Capture“ in Filme bzw. Bilder
    private static func appFolder(_ directory: FileManager.SearchPathDirectory) throws -> URL {
        let base = try FileManager.default.url(for: directory, in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = base.appendingPathComponent("HDMI Capture", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func recordingsFolder() throws -> URL { try appFolder(.moviesDirectory) }
    private static func snapshotsFolder() throws -> URL { try appFolder(.picturesDirectory) }

    /// „HDMI Capture 2026-10-23 um 21.55.12.png“; existiert der Name schon, wird „ 2“, „ 3“ … angehängt.
    private static func newFileURL(in folder: URL, ext: String) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'um' HH.mm.ss"
        let base = "HDMI Capture \(formatter.string(from: Date()))"
        var url = folder.appendingPathComponent("\(base).\(ext)")
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(number).\(ext)")
            number += 1
        }
        return url
    }

    // MARK: - Menü

    private func buildMenu() {
        let mainMenu = NSMenu()
        func submenu(_ title: String, _ fill: (NSMenu) -> Void) -> NSMenu {
            let item = NSMenuItem()
            let menu = NSMenu(title: title)
            fill(menu)
            item.submenu = menu
            mainMenu.addItem(item)
            return menu
        }

        _ = submenu("HDMI Capture") { m in
            m.addItem(withTitle: "Über HDMI Capture", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
            m.addItem(.separator())
            m.addItem(withTitle: "HDMI Capture ausblenden", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
            let others = m.addItem(withTitle: "Andere ausblenden", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            others.keyEquivalentModifierMask = [.command, .option]
            m.addItem(withTitle: "Alle einblenden", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
            m.addItem(.separator())
            m.addItem(withTitle: "HDMI Capture beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        }
        _ = submenu("Aufnahme") { m in
            let record = m.addItem(withTitle: "Aufnahme starten", action: #selector(toggleRecording(_:)), keyEquivalent: "r")
            record.target = self
            record.tag = 1
            m.addItem(.separator())
            m.addItem(withTitle: "Bildschirmfoto sichern", action: #selector(takeSnapshot(_:)), keyEquivalent: "s").target = self
            m.addItem(withTitle: "Bild kopieren", action: #selector(copySnapshot(_:)), keyEquivalent: "c").target = self
            m.addItem(.separator())
            m.addItem(withTitle: "Aufnahmeordner zeigen", action: #selector(showRecordings(_:)), keyEquivalent: "").target = self
            m.addItem(withTitle: "Bildschirmfotos zeigen", action: #selector(showSnapshots(_:)), keyEquivalent: "").target = self
        }
        _ = submenu("Ton") { m in
            let swap = m.addItem(withTitle: "Links/Rechts tauschen", action: #selector(toggleSwap(_:)), keyEquivalent: "l")
            swap.target = self
            swap.tag = 2
            m.addItem(.separator())
            m.addItem(withTitle: "Lauter", action: #selector(volumeUp(_:)), keyEquivalent: "\u{F700}").target = self
            m.addItem(withTitle: "Leiser", action: #selector(volumeDown(_:)), keyEquivalent: "\u{F701}").target = self
        }
        _ = submenu("Darstellung") { m in
            let full = m.addItem(withTitle: "Vollbild", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            full.keyEquivalentModifierMask = [.command, .control]
            let pin = m.addItem(withTitle: "Immer im Vordergrund", action: #selector(togglePin(_:)), keyEquivalent: "t")
            pin.target = self
            pin.tag = 3
        }
        let windowMenu = submenu("Fenster") { m in
            m.addItem(withTitle: "Im Dock ablegen", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
            m.addItem(withTitle: "Zoomen", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
            m.addItem(.separator())
            m.addItem(withTitle: "Alle nach vorne bringen", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        }
        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.tag {
        case 1: menuItem.title = isRecording ? "Aufnahme beenden" : "Aufnahme starten"
        case 2: menuItem.state = defaults.bool(forKey: "swapChannels") ? .on : .off
        case 3: menuItem.state = defaults.bool(forKey: "alwaysOnTop") ? .on : .off
        default: break
        }
        return true
    }
}
