import AppKit
import DotCleanCore
import Foundation
import ServiceManagement

private enum DefaultsKey {
    static let watcherEnabled = "watcherEnabled"
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let log = Log()
    private lazy var watcher = Watcher(log: log)
    private lazy var rules = RuleSet.standard

    private var watcherEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: DefaultsKey.watcherEnabled) == nil { return true }
            return UserDefaults.standard.bool(forKey: DefaultsKey.watcherEnabled)
        }
        set { UserDefaults.standard.set(newValue, forKey: DefaultsKey.watcherEnabled) }
    }

    private var isBusy = false

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "sparkles",
                                   accessibilityDescription: "DotClean")
            button.image?.isTemplate = true
            button.toolTip = "DotClean"
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        guard let log else {
            NSLog("DotClean: log unavailable")
            return
        }
        watcher.onDelete = { path in log.write("APP   deleted \(path)") }

        if watcherEnabled { watcher.start() }
        log.write("APP   launched (watcher \(watcherEnabled ? "on" : "off"))")
    }

    func applicationWillTerminate(_ notification: Notification) {
        watcher.stop()
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(title: "DotClean", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let deleted = NSMenuItem(title: "Watcher removed \(watcher.stats.deleted) items this session",
                                 action: nil, keyEquivalent: "")
        deleted.isEnabled = false
        menu.addItem(deleted)
        menu.addItem(.separator())

        let volumes = VolumeList.targets()
        if volumes.isEmpty {
            let none = NSMenuItem(title: "No non-Mac volumes mounted", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            for volume in volumes {
                let parent = NSMenuItem(title: volume.summary, action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                submenu.addItem(item("Scan…", #selector(scanVolume(_:)), volume.mountPoint))
                submenu.addItem(item("Clean…", #selector(cleanVolume(_:)), volume.mountPoint))
                if volume.isRemovable || !volume.isLocal {
                    submenu.addItem(item("Clean & Eject", #selector(cleanAndEject(_:)), volume.mountPoint))
                }
                parent.submenu = submenu
                menu.addItem(parent)
            }
        }

        menu.addItem(.separator())
        menu.addItem(item("Clean Folder…", #selector(chooseFolder(_:)), nil))
        menu.addItem(item("Sweep All Volumes…", #selector(sweepAll(_:)), nil))
        menu.addItem(.separator())

        let watcherItem = item(watcherEnabled ? "Watcher: On" : "Watcher: Off",
                               #selector(toggleWatcher(_:)), nil)
        watcherItem.state = watcherEnabled ? .on : .off
        menu.addItem(watcherItem)

        let login = item("Open at Login", #selector(toggleLoginItem(_:)), nil)
        login.state = loginItemEnabled ? .on : .off
        menu.addItem(login)

        menu.addItem(item("Show Log", #selector(showLog(_:)), nil))
        menu.addItem(.separator())
        menu.addItem(item("Quit DotClean", #selector(quit(_:)), "q"))
    }

    private func item(_ title: String, _ selector: Selector, _ represented: String?) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        menuItem.target = self
        menuItem.representedObject = represented
        return menuItem
    }

    // MARK: - Actions

    @objc private func scanVolume(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        preview(path: path, ejectAfter: false, alreadyConfirmed: true)
    }

    @objc private func cleanVolume(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        preview(path: path, ejectAfter: false, alreadyConfirmed: false)
    }

    @objc private func cleanAndEject(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        preview(path: path, ejectAfter: true, alreadyConfirmed: false)
    }

    @objc private func chooseFolder(_ sender: NSMenuItem) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Clean"
        panel.message = "Choose a folder or volume to clean"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        preview(path: url.path, ejectAfter: false, alreadyConfirmed: false)
    }

    @objc private func sweepAll(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "Sweep all non-Mac volumes?"
        alert.informativeText = "Scans every mounted non-Mac volume with the live rule set. "
            + "This can take a while on network shares."
        alert.addButton(withTitle: "Sweep")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        watcher.sweepNow()
    }

    @objc private func toggleWatcher(_ sender: NSMenuItem) {
        watcherEnabled.toggle()
        if watcherEnabled {
            watcher.start()
        } else {
            watcher.stop()
        }
        log?.write("APP   watcher \(watcherEnabled ? "on" : "off")")
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        do {
            if loginItemEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            alert(title: "Could not change login item",
                  body: error.localizedDescription
                    + "\n\nThis only works when DotClean is installed in /Applications.")
        }
    }

    @objc private func showLog(_ sender: NSMenuItem) {
        guard let path = log?.path else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    private var loginItemEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    // MARK: - Services (Finder right-click)

    @objc func cleanUsingDotClean(_ pasteboard: NSPasteboard) {
        let urls = Self.urls(from: pasteboard)
    guard !urls.isEmpty else { return }
        for url in urls {
            preview(path: url.path, ejectAfter: false, alreadyConfirmed: false)
        }
    }

    private static func urls(from pasteboard: NSPasteboard) -> [URL] {
        var urls: [URL] = []
        if let items = pasteboard.pasteboardItems {
            for item in items {
                if let string = item.string(forType: .fileURL),
                   let url = URL(string: string) {
                    urls.append(url)
                }
            }
        }
        if urls.isEmpty,
           let paths = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            urls = paths.map { URL(fileURLWithPath: $0) }
        }
        return urls
    }

    // MARK: - Flow

    private func preview(path: String, ejectAfter: Bool, alreadyConfirmed: Bool) {
        guard !isBusy else { return }
        let standardized = (path as NSString).standardizingPath

        if PathGuard.isForbidden(standardized) {
            alert(title: "Refused", body: "\(standardized) is a protected system path.")
            return
        }

        let volume = Volume(mountPoint: standardized,
                            fsType: FSInfo.type(of: standardized) ?? "unknown",
                            isLocal: true,
                            isRemovable: false,
                            isInternal: false)

        if volume.isMacFormat {
            let alert = NSAlert()
            alert.messageText = "\(standardized) is on a \(volume.fsType) volume"
            alert.informativeText = "This is a Mac format. Deleting metadata here only affects Finder "
                + "cosmetics, but it is unusual. Clean anyway?"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Clean Anyway")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        isBusy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let plan = Scanner(rules: self.rules, scope: .adhoc)
                .scan(root: URL(fileURLWithPath: standardized))

            DispatchQueue.main.async {
                self.isBusy = false

                if plan.isEmpty {
                    self.alert(title: "Nothing to clean",
                               body: plan.errors.isEmpty
                                    ? "No macOS metadata found."
                                    : plan.errors.prefix(5).joined(separator: "\n"))
                    return
                }

                guard alreadyConfirmed || self.confirm(plan: plan) else { return }

                self.isBusy = true
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = Executor.execute(plan, dryRun: false, log: self.log)
                    var body = result.summary()
                    if !result.failures.isEmpty {
                        body += "\n\n\(result.failures.count) item(s) could not be removed."
                        for failure in result.failures.prefix(5) {
                            body += "\n  \(failure.path) — \(failure.reason)"
                        }
                    }

                    if ejectAfter {
                        switch Disk.eject(path: standardized) {
                        case .success: body += "\n\nEjected."
                        case .failure(let message): body += "\n\nEject failed: \(message)"
                        }
                    }

                    DispatchQueue.main.async {
                        self.isBusy = false
                        self.alert(title: "Clean finished", body: body)
                    }
                }
            }
        }
    }

    private func confirm(plan: Plan) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Clean \(plan.root)?"
        alert.informativeText = "\(plan.items.count) item(s), "
            + ByteCountFormatter.string(fromByteCount: plan.totalBytes, countStyle: .file)
            + " will be removed. This cannot be undone."
        alert.alertStyle = .warning

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 240))
        let textView = NSTextView(frame: scroll.bounds)
        textView.isEditable = false
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.string = plan.prettyText(samples: 40)
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        alert.accessoryView = scroll

        alert.addButton(withTitle: "Clean")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func alert(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
