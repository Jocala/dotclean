import AppKit
import DotCleanCore

/// The one place the app talks to jocala.com. Called only from the
/// "Check for Updates…" menu item and the About panel button — there is no
/// startup check, so the app makes no outbound connection until asked.
enum UpdateUI {
    private static var inFlight = false

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    /// Manual check. `completion` runs on the main thread once the result has
    /// been shown (or immediately if a check was already in flight).
    static func check(completion: (() -> Void)? = nil) {
        guard !inFlight else {
            completion?()
            return
        }
        inFlight = true

        Updates.fetchPublished { result in
            DispatchQueue.main.async {
                inFlight = false
                switch result {
                case .failure(let error):
                    alert(title: "Check for Updates",
                          body: "Could not reach \(Updates.versionURL.absoluteString).\n\n"
                              + error.localizedDescription,
                          style: .warning)
                case .success(let published):
                    let version = published.trimmingCharacters(in: .whitespacesAndNewlines)
                    if Updates.isNewer(version, than: currentVersion) {
                        offer(version: version)
                    } else {
                        alert(title: "Check for Updates",
                              body: "DotClean \(currentVersion) is up to date.",
                              style: .informational)
                    }
                }
                completion?()
            }
        }
    }

    private static func offer(version: String) {
        let alert = NSAlert()
        alert.messageText = "DotClean \(version) is ready."
        alert.informativeText = "You are running \(currentVersion). "
            + "The download page has the current disk image."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(Updates.homeURL)
        }
    }

    private static func alert(title: String, body: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = style
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
