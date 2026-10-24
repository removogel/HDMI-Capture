import AppKit

/// Einstellungen: aus welchen Netzen der Stream abgerufen werden darf.
/// Änderungen gelten sofort, auch für einen laufenden Stream.
final class SettingsWindowController: NSWindowController, NSTextViewDelegate {
    /// Neuer Text der Zugriffsliste
    var onChange: ((String) -> Void)?

    private var textView: NSTextView!
    private let statusLabel = NSTextField(wrappingLabelWithString: "")

    init(text: String) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Einstellungen"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContent(text: text)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("nicht unterstützt") }

    private func buildContent(text: String) {
        guard let content = window?.contentView else { return }

        let title = NSTextField(labelWithString: "Stream: Zugriff erlauben aus")
        title.font = .boldSystemFont(ofSize: 13)

        let explanation = NSTextField(wrappingLabelWithString:
            "Ein Netz pro Zeile, zum Beispiel 192.168.x.x, 10.x.x.x, 192.168.178.0/24 oder eine einzelne Adresse "
            + "wie 192.168.178.30. IPv6 geht auch (fd00::/8). Text nach # ist ein Kommentar. "
            + "Verbindungen von anderen Adressen lehnt die App ab. Der Mac selbst hat immer Zugriff.")
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

        let resetButton = NSButton(title: "Standard wiederherstellen", target: self, action: #selector(resetToDefault))
        resetButton.bezelStyle = .rounded

        let stack = NSStackView(views: [title, explanation, scrollView, statusLabel, resetButton])
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

    @objc private func resetToDefault() {
        textView.string = NetworkAccessList.defaultText
        onChange?(textView.string)
        updateStatus()
    }

    private func updateStatus() {
        let list = NetworkAccessList(text: textView.string)
        if list.invalidLines.isEmpty == false {
            statusLabel.stringValue = "Nicht erkannt: " + list.invalidLines.joined(separator: ", ")
            statusLabel.textColor = .systemRed
        } else if list.subnets.isEmpty {
            statusLabel.stringValue = "Kein Netz freigegeben – nur der Mac selbst kann den Stream abrufen."
            statusLabel.textColor = .systemOrange
        } else {
            statusLabel.stringValue = "Freigegeben: " + list.summary
            statusLabel.textColor = .secondaryLabelColor
        }
    }
}
