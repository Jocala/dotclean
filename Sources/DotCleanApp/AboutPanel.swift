import AppKit
import DotCleanCore
import Foundation

/// Cursor feedback for the borderless link and donation-image buttons.
private final class HandButton: NSButton {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// About panel, laid out like Catalog's aboutdialog.cpp: product name, version,
/// site link, donation sentence with the PayPal button image, and a manual
/// "Check for Updates" button. No traffic happens unless the button is pressed.
final class AboutPanelController: NSWindowController {
    private let statusLabel = NSTextField(labelWithString: "")
    private var updateButton: NSButton!

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 340),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.title = "About DotClean"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func showWindow(_ sender: Any?) {
        statusLabel.stringValue = ""
        statusLabel.isHidden = true
        window?.center()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Layout

    private func build() {
        guard let window, let content = window.contentView else { return }

        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64),
        ])

        let name = NSTextField(labelWithString: "DotClean")
        name.font = .systemFont(ofSize: 17, weight: .bold)
        name.alignment = .center

        let version = NSTextField(labelWithString: "Version \(UpdateUI.currentVersion)")
        version.font = .systemFont(ofSize: 11)
        version.textColor = .secondaryLabelColor
        version.alignment = .center

        let site = HandButton(title: "", target: self, action: #selector(openHome))
        site.attributedTitle = NSAttributedString(string: "www.jocala.com", attributes: [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .font: NSFont.systemFont(ofSize: 11),
        ])
        site.isBordered = false
        site.refusesFirstResponder = true

        let thanks = NSTextField(wrappingLabelWithString:
            "Donations defray server costs and fund development.")
        thanks.font = .systemFont(ofSize: 11)
        thanks.textColor = .secondaryLabelColor
        thanks.alignment = .center
        thanks.preferredMaxLayoutWidth = 360

        let donate: NSView
        if let url = Bundle.main.url(forResource: "donatel", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            let button = HandButton(image: image, target: self, action: #selector(openDonate))
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.isBordered = false
            button.refusesFirstResponder = true
            donate = button
        } else {
            let button = HandButton(title: "Donate via PayPal",
                                    target: self, action: #selector(openDonate))
            button.bezelStyle = .rounded
            button.refusesFirstResponder = true
            donate = button
        }

        let updates = NSButton(title: "Check for Updates",
                               target: self, action: #selector(checkForUpdates))
        updates.bezelStyle = .rounded
        updateButton = updates

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.isHidden = true

        let close = NSButton(title: "Close", target: self, action: #selector(closePanel))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\r"

        let stack = NSStackView(views: [icon, name, version, site, thanks,
                                        donate, updates, statusLabel, close])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 7
        stack.setCustomSpacing(14, after: thanks)
        stack.setCustomSpacing(18, after: donate)
        stack.setCustomSpacing(16, after: updates)
        stack.setCustomSpacing(0, after: statusLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
        ])

        content.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 420, height: stack.fittingSize.height + 36))
        window.initialFirstResponder = close
    }

    // MARK: - Actions

    @objc private func openHome() {
        NSWorkspace.shared.open(Updates.homeURL)
    }

    @objc private func openDonate() {
        NSWorkspace.shared.open(Updates.donateURL)
    }

    @objc private func closePanel() {
        close()
    }

    @objc private func checkForUpdates() {
        guard updateButton.isEnabled else { return }
        updateButton.isEnabled = false
        statusLabel.stringValue = "Checking…"
        statusLabel.isHidden = false
        UpdateUI.check {
            self.statusLabel.stringValue = ""
            self.statusLabel.isHidden = true
            self.updateButton.isEnabled = true
        }
    }
}
