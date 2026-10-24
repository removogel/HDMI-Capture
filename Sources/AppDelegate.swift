import AppKit
import AVFoundation
import CoreImage

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation, NSMenuDelegate {
    private let engine = CaptureEngine()
    private let defaults = UserDefaults.standard

    private var window: NSWindow!
    private var preview: PreviewView!
    private let controls = NSVisualEffectView()
    private let statusPill = NSVisualEffectView()
    private let statusLabel = NSTextField(labelWithString: "Starting …")
    private let recordButton = NSButton(title: "Record", target: nil, action: nil)
    private let swapBox = NSButton(checkboxWithTitle: "Swap L/R", target: nil, action: nil)
    private let pinBox = NSButton(checkboxWithTitle: "Always on top", target: nil, action: nil)
    private let volumeSlider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let meter = LevelMeterView()
    private let fullscreenButton = NSButton(title: "", target: nil, action: nil)
    private let snapshotButton = NSButton(title: "", target: nil, action: nil)
    private let shutter = ShutterView(frame: .zero)
    private let streamButton = NSButton(title: "Stream", target: nil, action: nil)
    private let streamPanel = NSVisualEffectView()
    private let tsField = NSTextField(labelWithString: "")
    private let hlsField = NSTextField(labelWithString: "")
    private let dashField = NSTextField(labelWithString: "")
    private let rtspField = NSTextField(labelWithString: "")
    private let accessField = NSTextField(labelWithString: "")
    private let qrView = NSImageView()
    private let qrTargetControl = NSSegmentedControl(labels: ["VLC", "Browser"], trackingMode: .selectOne,
                                                     target: nil, action: nil)
    private var inputMenu: NSMenu?
    private var settingsController: SettingsWindowController?
    private var lastRejectionNotice: [String: Date] = [:]
    private var deviceObservers: [NSObjectProtocol] = []

    private var hideTimer: Timer?
    private var recTimer: Timer?
    private var recStart: Date?
    private var isRecording = false
    private var isStreaming = false
    private var streamStarting = false
    private var viewers = 0
    private var streamAddresses: StreamAddresses?
    /// Was die Capture-Engine zuletzt eingerichtet hat (Geräte, Bildrate)
    private var activeSetup: CaptureSetup?
    private var modeText = "Waiting for video …"
    private var flashText: String?
    private var flashID = 0
    private var shownLevels: (Float, Float) = (0, 0)
    private var activity: NSObjectProtocol?

    // MARK: - App-Lebenszyklus

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: ["volume": 1.0, "swapChannels": false, "alwaysOnTop": false,
                                     "streamAllowedNetworks": NetworkAccessList.defaultText,
                                     "dashSegmentFrames": StreamSettings.defaultSegmentFrames,
                                     "streamBitRate": StreamSettings.defaultBitRate,
                                     "recordingBitRate": StreamSettings.defaultBitRate,
                                     "frameRate": StreamSettings.defaultFrameRate,
                                     "streamCodec": VideoCodec.h264.rawValue,
                                     "recordingCodec": VideoCodec.h264.rawValue,
                                     "videoDeviceID": "", "audioDeviceID": "",
                                     "qrTarget": 0])
        buildMenu()
        buildWindow()

        engine.onLevels = { [weak self] l, r in self?.updateLevels(l, r) }
        engine.onStats = { [weak self] fps, w, h in self?.updateStats(fps: fps, width: w, height: h) }
        engine.onViewers = { [weak self] count in
            guard let self, self.isStreaming else { return }
            self.viewers = count
            self.updateStatus()
        }
        engine.onStreamRejected = { [weak self] host in self?.noteRejection(host) }
        engine.onRecordingFailed = { [weak self] url, reason in self?.recordingFailed(url, reason: reason) }
        engine.setSwap(defaults.bool(forKey: "swapChannels"))
        engine.monitor.volume = defaults.float(forKey: "volume")
        engine.start(options: captureOptions) { [weak self] setup in
            self?.applySetup(setup, announce: false)
        }
        observeDevices()

        activity = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated],
                                                         reason: "Live preview of the capture card")
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(preview)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard isRecording else { return .terminateNow }
        // Laufende Aufnahme erst sauber abschließen
        engine.stopRecording { _, _ in NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        deviceObservers.forEach { NotificationCenter.default.removeObserver($0) }
        engine.stopStreaming()
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
        window.minSize = NSSize(width: 960, height: 540)
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
        // Ziffern gleich breit, damit der Knopf beim Hochzählen der Aufnahmedauer nicht zappelt
        recordButton.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        snapshotButton.target = self
        snapshotButton.action = #selector(takeSnapshot(_:))
        snapshotButton.image = NSImage(systemSymbolName: "camera", accessibilityDescription: "Screenshot")
        snapshotButton.imagePosition = .imageOnly
        snapshotButton.toolTip = "Save screenshot (⌘S)"
        streamButton.target = self
        streamButton.action = #selector(toggleStreaming(_:))
        streamButton.image = NSImage(systemSymbolName: "dot.radiowaves.left.and.right", accessibilityDescription: "Stream")
        streamButton.imagePosition = .imageLeading
        streamButton.toolTip = "Start/stop streaming to the local network (⌘K)"
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
        fullscreenButton.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Full screen")
        fullscreenButton.imagePosition = .imageOnly
        let speaker = NSImageView()
        speaker.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Volume")
        speaker.contentTintColor = .secondaryLabelColor
        meter.toolTip = "Level left / right"

        let stack = NSStackView(views: [recordButton, snapshotButton, Self.divider(), streamButton, Self.divider(), swapBox, speaker, volumeSlider, meter,
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

        let panelStack = buildStreamPanel()

        for view in [preview, shutter, controls, statusPill, stack, statusLabel, meter, volumeSlider,
                     streamPanel, panelStack] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        content.addSubview(preview)
        content.addSubview(shutter)
        content.addSubview(controls)
        content.addSubview(statusPill)
        content.addSubview(streamPanel)

        NSLayoutConstraint.activate([
            panelStack.leadingAnchor.constraint(equalTo: streamPanel.leadingAnchor),
            panelStack.trailingAnchor.constraint(equalTo: streamPanel.trailingAnchor),
            panelStack.topAnchor.constraint(equalTo: streamPanel.topAnchor),
            panelStack.bottomAnchor.constraint(equalTo: streamPanel.bottomAnchor),
            streamPanel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            streamPanel.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor, constant: 8),
        ])

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

    /// Adressen des Streams und QR-Code (oben links, nur während des Streams sichtbar)
    private func buildStreamPanel() -> NSStackView {
        let panelTitle = NSTextField(labelWithString: "Streaming to the local network")
        panelTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        panelTitle.textColor = .white
        var rows: [[NSView]] = []
        for (name, field) in [("MPEG-TS", tsField), ("HLS", hlsField), ("MPEG-DASH", dashField), ("RTSP", rtspField)] {
            let label = NSTextField(labelWithString: name)
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = .secondaryLabelColor
            field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            field.textColor = .white
            field.isSelectable = true
            rows.append([label, field])
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 4
        grid.columnSpacing = 10
        let panelHint = NSTextField(labelWithString: "In VLC: Network → Open Network Stream")
        panelHint.font = .systemFont(ofSize: 11)
        panelHint.textColor = .secondaryLabelColor
        accessField.font = .systemFont(ofSize: 11)
        accessField.textColor = .secondaryLabelColor
        let addressStack = NSStackView(views: [grid, panelHint, accessField])
        addressStack.orientation = .vertical
        addressStack.alignment = .leading
        addressStack.spacing = 6

        // QR-Code auf weißem Grund (Ruhezone), darunter die Wahl des Ziels
        let qrSize: CGFloat = 112
        qrView.imageScaling = .scaleProportionallyUpOrDown
        qrView.wantsLayer = true
        qrView.layer?.magnificationFilter = .nearest
        qrView.layer?.minificationFilter = .nearest
        qrView.toolTip = "Scan with the iPad or iPhone camera"
        let qrBackground = NSView()
        qrBackground.wantsLayer = true
        qrBackground.layer?.backgroundColor = NSColor.white.cgColor
        qrBackground.layer?.cornerRadius = 6
        qrBackground.addSubview(qrView)
        qrTargetControl.target = self
        qrTargetControl.action = #selector(qrTargetChanged(_:))
        qrTargetControl.controlSize = .small
        qrTargetControl.selectedSegment = min(max(defaults.integer(forKey: "qrTarget"), 0), 1)
        qrTargetControl.setToolTip("Open the stream in VLC", forSegment: 0)
        qrTargetControl.setToolTip("Open the player page in Safari", forSegment: 1)
        let qrCaption = NSTextField(labelWithString: "Scan with the iPad")
        qrCaption.font = .systemFont(ofSize: 10)
        qrCaption.textColor = .secondaryLabelColor
        let qrStack = NSStackView(views: [qrBackground, qrTargetControl, qrCaption])
        qrStack.orientation = .vertical
        qrStack.alignment = .centerX
        qrStack.spacing = 6
        for view in [qrView, qrBackground] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            qrView.widthAnchor.constraint(equalToConstant: qrSize),
            qrView.heightAnchor.constraint(equalToConstant: qrSize),
            qrView.leadingAnchor.constraint(equalTo: qrBackground.leadingAnchor, constant: 8),
            qrView.trailingAnchor.constraint(equalTo: qrBackground.trailingAnchor, constant: -8),
            qrView.topAnchor.constraint(equalTo: qrBackground.topAnchor, constant: 8),
            qrView.bottomAnchor.constraint(equalTo: qrBackground.bottomAnchor, constant: -8),
        ])

        let body = NSStackView(views: [addressStack, qrStack])
        body.orientation = .horizontal
        body.alignment = .top
        body.spacing = 16

        let panelStack = NSStackView(views: [panelTitle, body])
        panelStack.orientation = .vertical
        panelStack.alignment = .leading
        panelStack.spacing = 8
        panelStack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        Self.style(streamPanel, radius: 10)
        streamPanel.addSubview(panelStack)
        streamPanel.isHidden = true
        return panelStack
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

    /// QR-Code für einen Text, in Bildpunkten passend für Retina-Displays
    private static func qrImage(for text: String, points: CGFloat) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage, output.extent.width > 0 else { return nil }
        let scale = max(1, floor(points * 2 / output.extent.width))
        let scaled = output.samplingNearest().transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let image = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: scaled.extent.width / 2, height: scaled.extent.height / 2))
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        fullscreenButton.image = NSImage(systemSymbolName: "arrow.down.right.and.arrow.up.left", accessibilityDescription: "Exit full screen")
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        fullscreenButton.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Full screen")
        window.level = defaults.bool(forKey: "alwaysOnTop") ? .floating : .normal
    }

    // MARK: - Bedienleiste ein-/ausblenden

    private func showControls() {
        hideTimer?.invalidate()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            controls.animator().alphaValue = 1
            statusPill.animator().alphaValue = 1
            streamPanel.animator().alphaValue = 1
        }
        hideTimer = Timer.scheduledTimer(timeInterval: 3, target: self, selector: #selector(hideControlsIfIdle),
                                         userInfo: nil, repeats: false)
    }

    @objc private func hideControlsIfIdle() {
        let location = window.mouseLocationOutsideOfEventStream
        let overPanel = streamPanel.isHidden == false && streamPanel.bounds.contains(streamPanel.convert(location, from: nil))
        if controls.bounds.contains(controls.convert(location, from: nil)) || overPanel {
            showControls()
            return
        }
        let keepStatus = isRecording || isStreaming || flashText != nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.4
            controls.animator().alphaValue = 0
            streamPanel.animator().alphaValue = 0
            if keepStatus == false { statusPill.animator().alphaValue = 0 }
        }
        if window.styleMask.contains(.fullScreen) { NSCursor.setHiddenUntilMouseMoves(true) }
    }

    // MARK: - Anzeige

    /// Dauer als „00:12:34“
    private static func clock(_ seconds: Int) -> String {
        String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }

    private var recordingSeconds: Int {
        guard let start = recStart else { return 0 }
        return max(0, Int(Date().timeIntervalSince(start)))
    }

    private func updateStatus() {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let text = NSMutableAttributedString()
        if isRecording, recStart != nil {
            text.append(NSAttributedString(string: "● REC \(Self.clock(recordingSeconds))   ",
                                           attributes: [.foregroundColor: NSColor.systemRed, .font: font]))
        }
        if isStreaming {
            let audience = viewers == 0 ? "" : " · \(viewers) \(viewers == 1 ? "viewer" : "viewers")"
            text.append(NSAttributedString(string: "● LIVE\(audience)   ",
                                           attributes: [.foregroundColor: NSColor.systemGreen, .font: font]))
        }
        text.append(NSAttributedString(string: flashText ?? modeText,
                                       attributes: [.foregroundColor: NSColor.white, .font: font]))
        statusLabel.attributedStringValue = text
    }

    private func updateStats(fps: Double, width: Int, height: Int) {
        if let setup = activeSetup, setup.videoID == nil {
            modeText = "No capture device"
        } else {
            modeText = fps < 1 ? "No signal" : "\(width)×\(height) · \(Int(fps.rounded())) fps"
        }
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
        recordButton.title = isRecording ? "Stop \(Self.clock(recordingSeconds))" : "Record"
        recordButton.image = NSImage(systemSymbolName: isRecording ? "stop.circle.fill" : "record.circle",
                                     accessibilityDescription: nil)
        updateStatus()
        showControls()
    }

    // MARK: - Geräte

    private var captureOptions: CaptureOptions {
        let video = defaults.string(forKey: "videoDeviceID") ?? ""
        let audio = defaults.string(forKey: "audioDeviceID") ?? ""
        return CaptureOptions(videoDeviceID: video.isEmpty ? nil : video,
                              audioDeviceID: audio.isEmpty ? nil : audio,
                              frameRate: StreamSettings.validFrameRate(defaults.integer(forKey: "frameRate")))
    }

    private func applySetup(_ setup: CaptureSetup, announce: Bool) {
        activeSetup = setup
        if setup.videoID == nil { modeText = "No capture device" }
        if setup.notes.isEmpty == false {
            flash(setup.notes.joined(separator: " · "), seconds: 10)
        } else if announce {
            let names = [setup.videoName, setup.audioName ?? "no audio"].compactMap { $0 }
            flash("Input: " + names.joined(separator: " · "))
        }
        updateStatus()
    }

    private func reconfigureCapture(announce: Bool = true) {
        engine.reconfigure(options: captureOptions) { [weak self] setup in
            self?.applySetup(setup, announce: announce)
        }
    }

    /// Geräte ein- und ausstecken: ohne Bild oder bei Rückkehr des gewählten Geräts neu einrichten
    private func observeDevices() {
        let center = NotificationCenter.default
        deviceObservers.append(center.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil,
                                                  queue: .main) { [weak self] note in
            let device = note.object as? AVCaptureDevice
            MainActor.assumeIsolated { self?.deviceConnected(device) }
        })
        deviceObservers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil,
                                                  queue: .main) { [weak self] note in
            let device = note.object as? AVCaptureDevice
            MainActor.assumeIsolated { self?.deviceDisconnected(device) }
        })
    }

    private func deviceConnected(_ device: AVCaptureDevice?) {
        guard let device, let setup = activeSetup, isRecording == false else { return }
        let options = captureOptions
        let isVideo = device.hasMediaType(.video)
        let wanted = isVideo ? options.videoDeviceID : options.audioDeviceID
        let missing = isVideo ? setup.videoID == nil : (setup.audioID == nil && options.audioDeviceID != CaptureOptions.noAudio)
        if missing || device.uniqueID == wanted {
            reconfigureCapture()
        }
    }

    private func deviceDisconnected(_ device: AVCaptureDevice?) {
        guard let device, let setup = activeSetup else { return }
        guard device.uniqueID == setup.videoID || device.uniqueID == setup.audioID else { return }
        if isRecording {
            flash("“\(device.localizedName)” disconnected", seconds: 10)
        } else {
            // Automatisch auf ein anderes Gerät wechseln (oder melden, dass keins mehr da ist)
            reconfigureCapture()
        }
    }

    /// Menü „Input“ bei jedem Öffnen neu aufbauen – so erscheinen gerade angesteckte Geräte
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === inputMenu else { return }
        menu.removeAllItems()
        let options = captureOptions

        menu.addItem(.sectionHeader(title: "Video"))
        let videoAuto = options.videoDeviceID == nil
        menu.addItem(deviceItem(title: Self.automaticTitle(videoAuto ? activeSetup?.videoName : nil), id: "",
                                selected: videoAuto, action: #selector(selectVideoDevice(_:))))
        for (device, title) in Self.titled(CaptureEngine.videoDevices()) {
            menu.addItem(deviceItem(title: title, id: device.uniqueID, selected: options.videoDeviceID == device.uniqueID,
                                    action: #selector(selectVideoDevice(_:))))
        }

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Audio"))
        let audioAuto = options.audioDeviceID == nil
        menu.addItem(deviceItem(title: Self.automaticTitle(audioAuto ? activeSetup?.audioName : nil), id: "",
                                selected: audioAuto, action: #selector(selectAudioDevice(_:))))
        for (device, title) in Self.titled(CaptureEngine.audioDevices()) {
            menu.addItem(deviceItem(title: title, id: device.uniqueID, selected: options.audioDeviceID == device.uniqueID,
                                    action: #selector(selectAudioDevice(_:))))
        }
        menu.addItem(deviceItem(title: "No Audio", id: CaptureOptions.noAudio,
                                selected: options.audioDeviceID == CaptureOptions.noAudio,
                                action: #selector(selectAudioDevice(_:))))
    }

    private static func automaticTitle(_ active: String?) -> String {
        active.map { "Automatic (\($0))" } ?? "Automatic"
    }

    /// Gleichnamige Geräte (z. B. zwei Sticks „USB Video“) durchnummerieren
    private static func titled(_ devices: [AVCaptureDevice]) -> [(AVCaptureDevice, String)] {
        var seen: [String: Int] = [:]
        var counts: [String: Int] = [:]
        for device in devices { counts[device.localizedName, default: 0] += 1 }
        return devices.map { device in
            let name = device.localizedName
            guard counts[name, default: 0] > 1 else { return (device, name) }
            seen[name, default: 0] += 1
            return (device, "\(name) (\(seen[name, default: 1]))")
        }
    }

    private func deviceItem(title: String, id: String, selected: Bool, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = id
        item.state = selected ? .on : .off
        item.indentationLevel = 1
        return item
    }

    @objc func selectVideoDevice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        defaults.set(id, forKey: "videoDeviceID")
        reconfigureCapture()
    }

    @objc func selectAudioDevice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        defaults.set(id, forKey: "audioDeviceID")
        reconfigureCapture()
    }

    // MARK: - Aktionen

    @objc func toggleRecording(_ sender: Any?) {
        recordButton.isEnabled = false
        if isRecording {
            engine.stopRecording { [weak self] url, duration in
                guard let self else { return }
                let length = Self.clock(Int(duration.rounded()))
                self.endRecordingUI()
                if let url {
                    self.flash("Saved: \(url.lastPathComponent) (\(length))")
                } else {
                    self.flash("Recording failed")
                }
            }
        } else {
            let url: URL
            do {
                url = try Self.newFileURL(in: Self.recordingsFolder(), ext: "mp4")
            } catch {
                flash("Can't write to the Movies folder")
                recordButton.isEnabled = true
                return
            }
            let bitRate = StreamSettings.validMbits(defaults.integer(forKey: "recordingBitRate")) * 1_000_000
            let codec = VideoCodec(stored: defaults.string(forKey: "recordingCodec"))
            let frameRate = StreamSettings.validFrameRate(defaults.integer(forKey: "frameRate"))
            engine.startRecording(to: url, bitRate: bitRate, codec: codec, frameRate: frameRate) { [weak self] error in
                guard let self else { return }
                self.recordButton.isEnabled = true
                if let error {
                    self.flash("Can't record: \(error.localizedDescription)")
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

    private func endRecordingUI() {
        isRecording = false
        recStart = nil
        recTimer?.invalidate()
        recTimer = nil
        recordButton.isEnabled = true
        updateRecordUI()
    }

    /// Schreibfehler (z. B. Platte voll): Die Datei ist bis zum letzten Fragment abspielbar
    private func recordingFailed(_ url: URL, reason: String) {
        guard isRecording else { return }
        endRecordingUI()
        flash("Recording stopped: \(reason) – \(url.lastPathComponent) is kept up to that point", seconds: 15)
    }

    @objc private func recTick() {
        recordButton.title = "Stop \(Self.clock(recordingSeconds))"
        updateStatus()
    }

    @objc func showRecordings(_ sender: Any?) {
        if let folder = try? Self.recordingsFolder() { NSWorkspace.shared.open(folder) }
    }

    // MARK: - Stream

    @objc func toggleStreaming(_ sender: Any?) {
        if isStreaming {
            engine.stopStreaming()
            isStreaming = false
            streamAddresses = nil
            viewers = 0
            updateStreamUI()
            flash("Stream stopped")
            return
        }
        guard streamStarting == false else { return }
        streamStarting = true
        streamButton.isEnabled = false
        let settings = StreamSettings(segmentFrames: defaults.integer(forKey: "dashSegmentFrames"),
                                      videoMbits: defaults.integer(forKey: "streamBitRate"),
                                      codec: VideoCodec(stored: defaults.string(forKey: "streamCodec")),
                                      frameRate: defaults.integer(forKey: "frameRate"))
        engine.startStreaming(accessList: accessList, settings: settings) { [weak self] result in
            guard let self else { return }
            self.streamStarting = false
            self.streamButton.isEnabled = true
            switch result {
            case .success(let addresses):
                self.isStreaming = true
                self.streamAddresses = addresses
                self.viewers = 0
                self.flash("Streaming – \(settings.codec.shortName) \(settings.videoBitRate / 1_000_000) Mbit/s, "
                           + "segments \(StreamSettings.label(frames: settings.segmentFrames))")
            case .failure(let error):
                self.flash("Stream didn't start: \(error.localizedDescription)", seconds: 10)
            }
            self.updateStreamUI()
        }
    }

    @objc func copyStreamAddresses(_ sender: Any?) {
        guard let addresses = streamAddresses else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(addresses.summary, forType: .string)
        flash("Stream addresses copied")
    }

    private func updateStreamUI() {
        streamButton.title = isStreaming ? "Stop Stream" : "Stream"
        streamButton.contentTintColor = isStreaming ? .systemGreen : nil
        if let addresses = streamAddresses {
            tsField.stringValue = addresses.ts
            hlsField.stringValue = addresses.hls
            dashField.stringValue = addresses.dash
            rtspField.stringValue = addresses.rtsp
        }
        updateQRCode()
        updateAccessField()
        streamPanel.isHidden = isStreaming == false
        updateStatus()
        showControls()
    }

    /// QR-Code: VLC-Link zum MPEG-TS-Stream oder die Infoseite mit Player
    private func updateQRCode() {
        guard let addresses = streamAddresses else {
            qrView.image = nil
            return
        }
        let text = qrTargetControl.selectedSegment == 1 ? addresses.page : StreamAddresses.vlcLink(addresses.ts)
        qrView.image = Self.qrImage(for: text, points: 112)
    }

    @objc private func qrTargetChanged(_ sender: NSSegmentedControl) {
        defaults.set(sender.selectedSegment, forKey: "qrTarget")
        updateQRCode()
    }

    // MARK: - Zugriffsliste

    private var accessList: NetworkAccessList {
        NetworkAccessList(text: defaults.string(forKey: "streamAllowedNetworks") ?? NetworkAccessList.defaultText)
    }

    private func updateAccessField() {
        let list = accessList
        if let host = streamAddresses?.host, list.allows(address: host) == false {
            accessField.stringValue = "Warning: your network (\(host)) is not allowed – Settings ⌘,"
            accessField.textColor = .systemOrange
        } else if list.subnets.isEmpty {
            accessField.stringValue = "No network allowed – this Mac only · Settings ⌘,"
            accessField.textColor = .systemOrange
        } else {
            accessField.stringValue = "Access only from: \(list.summary) · Settings ⌘,"
            accessField.textColor = .secondaryLabelColor
        }
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsController == nil {
            let values = SettingsWindowController.Values(
                accessList: defaults.string(forKey: "streamAllowedNetworks") ?? NetworkAccessList.defaultText,
                segmentFrames: defaults.integer(forKey: "dashSegmentFrames"),
                frameRate: defaults.integer(forKey: "frameRate"),
                streamCodec: VideoCodec(stored: defaults.string(forKey: "streamCodec")),
                streamMbits: defaults.integer(forKey: "streamBitRate"),
                recordingCodec: VideoCodec(stored: defaults.string(forKey: "recordingCodec")),
                recordingMbits: defaults.integer(forKey: "recordingBitRate"))
            let controller = SettingsWindowController(values: values)
            controller.onChange = { [weak self] text in
                guard let self else { return }
                self.defaults.set(text, forKey: "streamAllowedNetworks")
                self.engine.updateStreamAccess(self.accessList)
                self.updateAccessField()
            }
            controller.onSegmentChange = { [weak self] frames in
                guard let self else { return }
                self.defaults.set(frames, forKey: "dashSegmentFrames")
                if self.isStreaming {
                    self.flash("New segment length applies the next time streaming starts")
                }
            }
            controller.onFrameRateChange = { [weak self] fps in
                guard let self else { return }
                self.defaults.set(fps, forKey: "frameRate")
                self.engine.setFrameRate(fps) { [weak self] applied, note in
                    guard let self else { return }
                    if let note {
                        self.flash(note, seconds: 10)
                    } else if let applied {
                        self.flash("Frame rate: \(Int(applied.rounded())) fps")
                    }
                }
            }
            controller.onStreamCodecChange = { [weak self] codec in
                guard let self else { return }
                self.defaults.set(codec.rawValue, forKey: "streamCodec")
                if self.isStreaming {
                    self.flash("New stream codec applies the next time streaming starts")
                }
            }
            controller.onRecordingCodecChange = { [weak self] codec in
                guard let self else { return }
                self.defaults.set(codec.rawValue, forKey: "recordingCodec")
                if self.isRecording {
                    self.flash("New recording codec applies to the next recording")
                }
            }
            controller.onStreamBitRateChange = { [weak self] mbits in
                guard let self else { return }
                self.defaults.set(mbits, forKey: "streamBitRate")
                if self.isStreaming {
                    self.flash("New stream bit rate applies the next time streaming starts")
                }
            }
            controller.onRecordingBitRateChange = { [weak self] mbits in
                guard let self else { return }
                self.defaults.set(mbits, forKey: "recordingBitRate")
                if self.isRecording {
                    self.flash("New recording bit rate applies to the next recording")
                }
            }
            settingsController = controller
        }
        // Bei „Always on Top“ sonst hinter dem Hauptfenster
        settingsController?.window?.level = window.level
        settingsController?.showWindow(nil)
        settingsController?.window?.makeKeyAndOrderFront(nil)
    }

    /// Hinweis auf abgewiesene Verbindungen – pro Adresse höchstens alle 10 s
    private func noteRejection(_ host: String) {
        let now = Date()
        if let last = lastRejectionNotice[host], now.timeIntervalSince(last) < 10 { return }
        lastRejectionNotice[host] = now
        flash("Connection from \(host) refused – allow its network in Settings", seconds: 8)
    }

    @objc func showSnapshots(_ sender: Any?) {
        if let folder = try? Self.snapshotsFolder() { NSWorkspace.shared.open(folder) }
    }

    @objc func takeSnapshot(_ sender: Any?) {
        engine.snapshot { [weak self] snapshot in
            guard let self else { return }
            guard let snapshot else {
                self.flash("No video signal for a screenshot")
                return
            }
            self.shutter.flash()
            do {
                let url = try Self.newFileURL(in: Self.snapshotsFolder(), ext: "png")
                try snapshot.png.write(to: url)
                self.flash("Screenshot: \(url.lastPathComponent)")
            } catch {
                self.flash("Screenshot not saved: \(error.localizedDescription)")
            }
        }
    }

    /// „Edit → Copy“ (⌘C), wenn kein Textfeld aktiv ist: aktuelles Bild kopieren
    @objc func copy(_ sender: Any?) {
        copySnapshot(sender)
    }

    @objc func copySnapshot(_ sender: Any?) {
        engine.snapshot { [weak self] snapshot in
            guard let self else { return }
            guard let snapshot else {
                self.flash("No video signal to copy")
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
            self.flash("Frame copied to the clipboard")
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

    /// „HDMI Capture 2026-10-23 at 21.55.12.png“; existiert der Name schon, wird „ 2“, „ 3“ … angehängt.
    private static func newFileURL(in folder: URL, ext: String) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
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
            m.addItem(withTitle: "About HDMI Capture", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
            m.addItem(.separator())
            m.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",").target = self
            m.addItem(.separator())
            m.addItem(withTitle: "Hide HDMI Capture", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
            let others = m.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            others.keyEquivalentModifierMask = [.command, .option]
            m.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
            m.addItem(.separator())
            m.addItem(withTitle: "Quit HDMI Capture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        }
        _ = submenu("Recording") { m in
            let record = m.addItem(withTitle: "Start Recording", action: #selector(toggleRecording(_:)), keyEquivalent: "r")
            record.target = self
            record.tag = 1
            m.addItem(.separator())
            m.addItem(withTitle: "Save Screenshot", action: #selector(takeSnapshot(_:)), keyEquivalent: "s").target = self
            m.addItem(withTitle: "Copy Frame", action: #selector(copySnapshot(_:)), keyEquivalent: "").target = self
            m.addItem(.separator())
            m.addItem(withTitle: "Show Recordings Folder", action: #selector(showRecordings(_:)), keyEquivalent: "").target = self
            m.addItem(withTitle: "Show Screenshots Folder", action: #selector(showSnapshots(_:)), keyEquivalent: "").target = self
        }
        // Edit: nötig für Textfelder (Einstellungen). ⌘C ohne Textauswahl kopiert das aktuelle Bild.
        _ = submenu("Edit") { m in
            m.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
            let redo = m.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
            redo.keyEquivalentModifierMask = [.command, .shift]
            m.addItem(.separator())
            m.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
            m.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
            m.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
            m.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        }
        // Input: Bild- und Tonquelle – wird bei jedem Öffnen aufgebaut (menuNeedsUpdate)
        inputMenu = submenu("Input") { m in
            m.delegate = self
        }
        _ = submenu("Stream") { m in
            let toggle = m.addItem(withTitle: "Start Streaming", action: #selector(toggleStreaming(_:)), keyEquivalent: "k")
            toggle.target = self
            toggle.tag = 4
            let copy = m.addItem(withTitle: "Copy Stream Addresses", action: #selector(copyStreamAddresses(_:)), keyEquivalent: "")
            copy.target = self
            copy.tag = 5
        }
        _ = submenu("Audio") { m in
            let swap = m.addItem(withTitle: "Swap Left/Right", action: #selector(toggleSwap(_:)), keyEquivalent: "l")
            swap.target = self
            swap.tag = 2
            m.addItem(.separator())
            m.addItem(withTitle: "Volume Up", action: #selector(volumeUp(_:)), keyEquivalent: "\u{F700}").target = self
            m.addItem(withTitle: "Volume Down", action: #selector(volumeDown(_:)), keyEquivalent: "\u{F701}").target = self
        }
        _ = submenu("View") { m in
            let full = m.addItem(withTitle: "Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            full.keyEquivalentModifierMask = [.command, .control]
            let pin = m.addItem(withTitle: "Always on Top", action: #selector(togglePin(_:)), keyEquivalent: "t")
            pin.target = self
            pin.tag = 3
        }
        let windowMenu = submenu("Window") { m in
            m.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
            m.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
            m.addItem(.separator())
            m.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        }
        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // Geräte nicht mitten in einer Aufnahme wechseln
        if menuItem.action == #selector(selectVideoDevice(_:)) || menuItem.action == #selector(selectAudioDevice(_:)) {
            return isRecording == false
        }
        switch menuItem.tag {
        case 1: menuItem.title = isRecording ? "Stop Recording" : "Start Recording"
        case 2: menuItem.state = defaults.bool(forKey: "swapChannels") ? .on : .off
        case 3: menuItem.state = defaults.bool(forKey: "alwaysOnTop") ? .on : .off
        case 4:
            menuItem.title = isStreaming ? "Stop Streaming" : "Start Streaming"
            return streamStarting == false
        case 5: return isStreaming
        default: break
        }
        return true
    }
}
