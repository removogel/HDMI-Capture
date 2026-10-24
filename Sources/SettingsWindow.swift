import AppKit

/// Einstellungen: freigegebene Netze (gilt sofort), DASH/HLS-Segmentlänge, Stream-Codec und -Bitrate
/// (beim nächsten Streamstart), Aufnahme-Codec und -Bitrate (bei der nächsten Aufnahme), Bildrate (sofort).
final class SettingsWindowController: NSWindowController, NSTextViewDelegate {
    struct Values {
        var accessList: String
        var segmentFrames: Int
        var frameRate: Int
        var streamCodec: VideoCodec
        var streamMbits: Int
        var recordingCodec: VideoCodec
        var recordingMbits: Int
    }

    /// Neuer Text der Zugriffsliste
    var onChange: ((String) -> Void)?
    /// Neue DASH/HLS-Segmentlänge in 1/30 s
    var onSegmentChange: ((Int) -> Void)?
    var onFrameRateChange: ((Int) -> Void)?
    var onStreamCodecChange: ((VideoCodec) -> Void)?
    var onRecordingCodecChange: ((VideoCodec) -> Void)?
    /// Neue Videobitraten in Mbit/s
    var onStreamBitRateChange: ((Int) -> Void)?
    var onRecordingBitRateChange: ((Int) -> Void)?

    private static let width: CGFloat = 500

    private var textView: NSTextView!
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let segmentPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let frameRatePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let streamCodecPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let recordingCodecPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let streamBitRatePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let recordingBitRatePopup = NSPopUpButton(frame: .zero, pullsDown: false)

    init(values: Values) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 760),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContent(values)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private static func title(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .boldSystemFont(ofSize: 13)
        return label
    }

    private static func explanation(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = width - 40
        return label
    }

    private static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func buildContent(_ values: Values) {
        guard let window, let content = window.contentView else { return }

        // Zugriffsliste
        let accessTitle = Self.title("Stream: allow access from")
        let accessExplanation = Self.explanation(
            "One network per line, for example 192.168.x.x, 10.x.x.x, 192.168.178.0/24 or a single address "
            + "such as 192.168.178.30. IPv6 works too (fd00::/8). Text after # is a comment. "
            + "The app refuses connections from other addresses. This Mac always has access.")

        let scrollView = NSTextView.scrollableTextView()
        scrollView.borderType = .bezelBorder
        textView = scrollView.documentView as? NSTextView
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.string = values.accessList
        textView.delegate = self

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.preferredMaxLayoutWidth = Self.width - 40

        let resetButton = NSButton(title: "Restore Default", target: self, action: #selector(resetToDefault))
        resetButton.bezelStyle = .rounded

        // Segmentlänge
        let segmentTitle = Self.title("MPEG-DASH and HLS: segment length")
        for frames in StreamSettings.segmentChoices {
            var itemTitle = StreamSettings.label(frames: frames)
            if frames == 16 { itemTitle += " – lowest latency" }
            if frames == StreamSettings.defaultSegmentFrames { itemTitle += " (default)" }
            if frames == 64 { itemTitle += " – more robust on weak Wi-Fi" }
            segmentPopup.addItem(withTitle: itemTitle)
            segmentPopup.lastItem?.tag = frames
        }
        segmentPopup.selectItem(withTag: StreamSettings(segmentFrames: values.segmentFrames).segmentFrames)
        segmentPopup.target = self
        segmentPopup.action = #selector(segmentChanged)
        let segmentExplanation = Self.explanation(
            "Shorter segments reduce the delay in players that stay a few segments behind the live edge "
            + "(e.g. dash.js, Safari). The lengths are chosen so that video and audio segments are exactly the same length. "
            + "Takes effect the next time streaming starts.")

        // Video: Bildrate, Codec und Bitrate für Stream und Aufnahme
        let videoTitle = Self.title("Video")
        for fps in StreamSettings.frameRateChoices {
            frameRatePopup.addItem(withTitle: fps == StreamSettings.defaultFrameRate ? "\(fps) fps (default)" : "\(fps) fps")
            frameRatePopup.lastItem?.tag = fps
        }
        frameRatePopup.selectItem(withTag: StreamSettings.validFrameRate(values.frameRate))
        frameRatePopup.target = self
        frameRatePopup.action = #selector(frameRateChanged)

        for (popup, codec) in [(streamCodecPopup, values.streamCodec), (recordingCodecPopup, values.recordingCodec)] {
            for (index, choice) in VideoCodec.allCases.enumerated() {
                popup.addItem(withTitle: choice == .h264 ? "\(choice.label) (default)" : choice.label)
                popup.lastItem?.tag = index
            }
            popup.selectItem(withTag: VideoCodec.allCases.firstIndex(of: codec) ?? 0)
            popup.target = self
            popup.action = #selector(codecChanged(_:))
        }
        for (popup, value) in [(streamBitRatePopup, values.streamMbits), (recordingBitRatePopup, values.recordingMbits)] {
            for mbits in StreamSettings.bitRateChoices {
                var itemTitle = "\(mbits) Mbit/s"
                if mbits == StreamSettings.defaultBitRate { itemTitle += " (default)" }
                popup.addItem(withTitle: itemTitle)
                popup.lastItem?.tag = mbits
            }
            popup.selectItem(withTag: StreamSettings.validMbits(value))
            popup.target = self
            popup.action = #selector(bitRateChanged(_:))
        }
        let videoGrid = NSGridView(views: [
            [NSTextField(labelWithString: "Frame rate:"), frameRatePopup, NSGridCell.emptyContentView],
            [NSTextField(labelWithString: "Stream:"), streamCodecPopup, streamBitRatePopup],
            [NSTextField(labelWithString: "Recording:"), recordingCodecPopup, recordingBitRatePopup],
        ])
        videoGrid.rowSpacing = 8
        videoGrid.columnSpacing = 10
        videoGrid.column(at: 0).xPlacement = .trailing
        let videoExplanation = Self.explanation(
            "60 fps needs a source that outputs 60 Hz and a higher bit rate; the frame rate applies immediately. "
            + "HEVC needs roughly half the bit rate of H.264 for the same picture. VLC, QuickTime and Safari play it, "
            + "Firefox doesn't (DASH). 16 Mbit/s is usually fine over Wi-Fi, 30 Mbit/s is better suited to a cable or "
            + "good reception. Stream settings apply the next time streaming starts, recording settings to the next recording.")

        let stack = NSStackView(views: [accessTitle, accessExplanation, scrollView, statusLabel, resetButton,
                                        Self.separator(), segmentTitle, segmentPopup, segmentExplanation,
                                        Self.separator(), videoTitle, videoGrid, videoExplanation])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        var constraints = [
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.width),
            scrollView.heightAnchor.constraint(equalToConstant: 130),
        ]
        for view in stack.arrangedSubviews where view is NSBox || view === scrollView || view === statusLabel
            || view === accessExplanation || view === segmentExplanation || view === videoExplanation {
            constraints.append(view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40))
        }
        NSLayoutConstraint.activate(constraints)
        updateStatus()

        // Fensterhöhe an den Inhalt anpassen
        stack.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: Self.width, height: ceil(stack.fittingSize.height)))
        stack.bottomAnchor.constraint(equalTo: content.bottomAnchor).isActive = true
    }

    func textDidChange(_ notification: Notification) {
        onChange?(textView.string)
        updateStatus()
    }

    @objc private func segmentChanged() {
        onSegmentChange?(segmentPopup.selectedTag())
    }

    @objc private func frameRateChanged() {
        onFrameRateChange?(frameRatePopup.selectedTag())
    }

    @objc private func codecChanged(_ sender: NSPopUpButton) {
        let codec = VideoCodec.allCases[max(0, min(sender.selectedTag(), VideoCodec.allCases.count - 1))]
        if sender === streamCodecPopup {
            onStreamCodecChange?(codec)
        } else {
            onRecordingCodecChange?(codec)
        }
    }

    @objc private func bitRateChanged(_ sender: NSPopUpButton) {
        if sender === streamBitRatePopup {
            onStreamBitRateChange?(sender.selectedTag())
        } else {
            onRecordingBitRateChange?(sender.selectedTag())
        }
    }

    @objc private func resetToDefault() {
        textView.string = NetworkAccessList.defaultText
        onChange?(textView.string)
        updateStatus()
    }

    private func updateStatus() {
        let list = NetworkAccessList(text: textView.string)
        if list.invalidLines.isEmpty == false {
            statusLabel.stringValue = "Not recognized: " + list.invalidLines.joined(separator: ", ")
            statusLabel.textColor = .systemRed
        } else if list.subnets.isEmpty {
            statusLabel.stringValue = "No network allowed – only this Mac can watch the stream."
            statusLabel.textColor = .systemOrange
        } else {
            statusLabel.stringValue = "Allowed: " + list.summary
            statusLabel.textColor = .secondaryLabelColor
        }
    }
}
