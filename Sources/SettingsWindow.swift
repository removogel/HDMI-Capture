import AppKit

/// Einstellungen: freigegebene Netze (gilt sofort), DASH-Segmentlänge und Stream-Bitrate (beim nächsten Streamstart),
/// Aufnahme-Bitrate (bei der nächsten Aufnahme).
final class SettingsWindowController: NSWindowController, NSTextViewDelegate {
    /// Neuer Text der Zugriffsliste
    var onChange: ((String) -> Void)?
    /// Neue DASH-Segmentlänge in Bildern
    var onSegmentChange: ((Int) -> Void)?
    /// Neue Videobitraten in Mbit/s
    var onStreamBitRateChange: ((Int) -> Void)?
    var onRecordingBitRateChange: ((Int) -> Void)?

    private var textView: NSTextView!
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let segmentPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let streamBitRatePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let recordingBitRatePopup = NSPopUpButton(frame: .zero, pullsDown: false)

    init(text: String, segmentFrames: Int, streamMbits: Int, recordingMbits: Int) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContent(text: text, segmentFrames: segmentFrames, streamMbits: streamMbits, recordingMbits: recordingMbits)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func buildContent(text: String, segmentFrames: Int, streamMbits: Int, recordingMbits: Int) {
        guard let content = window?.contentView else { return }

        let title = NSTextField(labelWithString: "Stream: allow access from")
        title.font = .boldSystemFont(ofSize: 13)

        let explanation = NSTextField(wrappingLabelWithString:
            "One network per line, for example 192.168.x.x, 10.x.x.x, 192.168.178.0/24 or a single address "
            + "such as 192.168.178.30. IPv6 works too (fd00::/8). Text after # is a comment. "
            + "The app refuses connections from other addresses. This Mac always has access.")
        explanation.font = .systemFont(ofSize: 11)
        explanation.textColor = .secondaryLabelColor

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
        textView.string = text
        textView.delegate = self

        statusLabel.font = .systemFont(ofSize: 11)

        let resetButton = NSButton(title: "Restore Default", target: self, action: #selector(resetToDefault))
        resetButton.bezelStyle = .rounded

        // DASH-Segmentlänge
        let separator = NSBox()
        separator.boxType = .separator
        let dashTitle = NSTextField(labelWithString: "MPEG-DASH: segment length")
        dashTitle.font = .boldSystemFont(ofSize: 13)
        for frames in StreamSettings.segmentChoices {
            var itemTitle = StreamSettings.label(frames: frames)
            if frames == 16 { itemTitle += " – lowest latency" }
            if frames == StreamSettings.defaultSegmentFrames { itemTitle += " (default)" }
            if frames == 64 { itemTitle += " – more robust on weak Wi-Fi" }
            segmentPopup.addItem(withTitle: itemTitle)
            segmentPopup.lastItem?.tag = frames
        }
        segmentPopup.selectItem(withTag: StreamSettings(segmentFrames: segmentFrames).segmentFrames)
        segmentPopup.target = self
        segmentPopup.action = #selector(segmentChanged)
        let dashExplanation = NSTextField(wrappingLabelWithString:
            "Shorter segments reduce the delay in players that stay a few segments behind the live edge "
            + "(e.g. dash.js). The lengths are chosen so that video and audio segments are exactly the same length. "
            + "Takes effect the next time streaming starts.")
        dashExplanation.font = .systemFont(ofSize: 11)
        dashExplanation.textColor = .secondaryLabelColor

        // Videobitraten
        let bitRateSeparator = NSBox()
        bitRateSeparator.boxType = .separator
        let bitRateTitle = NSTextField(labelWithString: "Video bit rate (H.264)")
        bitRateTitle.font = .boldSystemFont(ofSize: 13)
        for (popup, value) in [(streamBitRatePopup, streamMbits), (recordingBitRatePopup, recordingMbits)] {
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
        let bitRateGrid = NSGridView(views: [[NSTextField(labelWithString: "Stream:"), streamBitRatePopup],
                                             [NSTextField(labelWithString: "Recording:"), recordingBitRatePopup]])
        bitRateGrid.rowSpacing = 8
        bitRateGrid.columnSpacing = 10
        let bitRateExplanation = NSTextField(wrappingLabelWithString:
            "Higher bit rates give a better picture. 16 Mbit/s is usually fine over Wi-Fi, 30 Mbit/s is better "
            + "suited to a cable or good reception. Stream: applies the next time streaming starts. "
            + "Recording: applies to the next recording.")
        bitRateExplanation.font = .systemFont(ofSize: 11)
        bitRateExplanation.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [title, explanation, scrollView, statusLabel, resetButton,
                                        separator, dashTitle, segmentPopup, dashExplanation,
                                        bitRateSeparator, bitRateTitle, bitRateGrid, bitRateExplanation])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            dashExplanation.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            bitRateExplanation.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            bitRateSeparator.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            scrollView.heightAnchor.constraint(equalToConstant: 150),
        ])
        updateStatus()
    }

    func textDidChange(_ notification: Notification) {
        onChange?(textView.string)
        updateStatus()
    }

    @objc private func segmentChanged() {
        onSegmentChange?(segmentPopup.selectedTag())
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
