import Darwin
import Foundation

public struct Volume: Sendable, Codable, Equatable {
    public let mountPoint: String
    public let fsType: String
    /// `f_mntfromname`: `//jeff@192.168.1.39/storage` for shares, the device
    /// path for local disks. Empty when it could not be read.
    public let source: String
    public let isLocal: Bool
    public let isRemovable: Bool
    public let isInternal: Bool

    public init(mountPoint: String,
                fsType: String,
                source: String = "",
                isLocal: Bool,
                isRemovable: Bool,
                isInternal: Bool) {
        self.mountPoint = mountPoint
        self.fsType = fsType
        self.source = source
        self.isLocal = isLocal
        self.isRemovable = isRemovable
        self.isInternal = isInternal
    }

    /// Filesystems where `._`/`.DS_Store` are native and must be left alone.
    public var isMacFormat: Bool {
        ["apfs", "hfs", "hfsx"].contains(fsType.lowercased())
    }

    /// A mount whose bytes live on another machine. `fstype` alone cannot say
    /// whether the *remote* disk is Mac-formatted, so transport is tracked
    /// separately and never implies "safe to clean".
    public var isNetwork: Bool {
        ["smbfs", "cifs", "afpfs", "nfs", "webdav"].contains(fsType.lowercased())
    }

    /// Host part of a network mount's source, lowercased.
    public var networkHost: String? {
        guard isNetwork else { return nil }
        return Volume.host(from: source)
    }

    /// `//jeff@192.168.1.39/storage` → `192.168.1.39`.
    /// `192.168.1.39:/export/tv` → `192.168.1.39`.
    public static func host(from source: String) -> String? {
        var rest = source
        guard !rest.isEmpty else { return nil }
        if rest.hasPrefix("//") { rest.removeFirst(2) }

        if let colon = rest.firstIndex(of: ":"),
           !rest[rest.startIndex..<colon].contains("/") {
            rest = String(rest[rest.startIndex..<colon])
        }
        if let slash = rest.firstIndex(of: "/") {
            rest = String(rest[rest.startIndex..<slash])
        }
        if let at = rest.lastIndex(of: "@") {
            rest = String(rest[rest.index(after: at)...])
        }
        return rest.isEmpty ? nil : rest.lowercased()
    }

    /// Whether the watcher and `sweep` may touch this volume without being
    /// asked. Local non-Mac volumes always qualify; a network share only when
    /// its host is explicitly allowed, because an SMB share can front a Mac.
    public func allowsAutomaticClean(allowedHosts: Set<String>) -> Bool {
        if isMacFormat { return false }
        guard isNetwork else { return true }
        guard let host = networkHost else { return false }
        return allowedHosts.contains(host)
    }

    public var isTarget: Bool { !isMacFormat }

    public var name: String {
        mountPoint == "/" ? "Macintosh HD" : (mountPoint as NSString).lastPathComponent
    }

    public var summary: String {
        var where_ = isLocal ? "local" : "network"
        if let host = networkHost { where_ += " \(host)" }
        return "\(name) — \(fsType), \(where_)"
    }
}

/// Which network hosts the user trusts for live cleaning. Default: none — a
/// share is never cleaned behind your back until its host is named here.
///
/// Stored with CFPreferences rather than `UserDefaults(suiteName:)`: both the
/// app and the `bclean` binary must read the same domain, and a suite that
/// matches the caller's own bundle identifier is rejected by Foundation.
public enum NetworkPolicy {
    public static let domain = "com.jocala.dotclean" as CFString
    public static let allowedHostsKey = "watchNetworkHosts"

    public static var allowedHosts: Set<String> {
        let raw = CFPreferencesCopyAppValue(allowedHostsKey as CFString, domain) as? [String] ?? []
        return Set(raw.map { $0.lowercased() })
    }

    public static func setAllowed(host: String, _ allowed: Bool) {
        let host = host.lowercased()
        var hosts = allowedHosts
        if allowed { hosts.insert(host) } else { hosts.remove(host) }
        CFPreferencesSetAppValue(allowedHostsKey as CFString, hosts.sorted() as CFArray, domain)
        CFPreferencesAppSynchronize(domain)
    }
}

public enum FSInfo {
    public static func type(of path: String) -> String? {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return nil }
        return withUnsafeBytes(of: &s.f_fstypename) { raw in
            guard let base = raw.baseAddress else { return nil }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }

    /// `f_mntfromname`: the device for a local disk, `//user@host/share` for
    /// an SMB/AFP mount, `host:/export` for NFS.
    public static func source(of path: String) -> String? {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return nil }
        return withUnsafeBytes(of: &s.f_mntfromname) { raw in
            guard let base = raw.baseAddress else { return nil }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }

    /// Device id of whatever `path` resolves to (follows symlinks).
    public static func device(of path: String) -> dev_t? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return st.st_dev
    }

    /// Device id of `path` itself (does not follow symlinks).
    public static func linkDevice(of path: String) -> dev_t? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return st.st_dev
    }

    public struct Entry {
        public let isDirectory: Bool
        public let isSymlink: Bool
        public let device: dev_t
        public let size: Int64
    }

    public static func entry(at path: String) -> Entry? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let kind = st.st_mode & S_IFMT
        return Entry(isDirectory: kind == S_IFDIR,
                     isSymlink: kind == S_IFLNK,
                     device: st.st_dev,
                     size: Int64(st.st_size))
    }

    /// A path is a mount point when its device differs from its parent's.
    public static func isMountPoint(_ path: String) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        guard parent != path else { return true }
        guard let selfDev = linkDevice(of: path),
              let parentDev = linkDevice(of: parent) else { return false }
        return selfDev != parentDev
    }
}

public enum VolumeList {
    private static let resourceKeys: [URLResourceKey] = [
        .volumeIsLocalKey,
        .volumeIsRemovableKey,
        .volumeIsInternalKey,
    ]

    /// Browsable volumes, plus anything sitting in /Volumes (network shares and
    /// removable media are not always reported by mountedVolumeURLs).
    public static func all() -> [Volume] {
        var paths = Set<String>()

        if let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: resourceKeys,
            options: [.skipHiddenVolumes]
        ) {
            for url in urls { paths.insert(url.standardizedFileURL.path) }
        }

        if let listing = try? FileManager.default.contentsOfDirectory(atPath: "/Volumes") {
            for name in listing where !name.hasPrefix(".") {
                paths.insert("/Volumes/\(name)")
            }
        }

        return paths.compactMap { path -> Volume? in
            guard let fs = FSInfo.type(of: path) else { return nil }
            let url = URL(fileURLWithPath: path)
            let values = try? url.resourceValues(forKeys: Set(resourceKeys))
            return Volume(
                mountPoint: path,
                fsType: fs,
                source: FSInfo.source(of: path) ?? "",
                isLocal: values?.volumeIsLocal ?? true,
                isRemovable: values?.volumeIsRemovable ?? false,
                isInternal: values?.volumeIsInternal ?? false
            )
        }
        .sorted { $0.mountPoint.localizedStandardCompare($1.mountPoint) == .orderedAscending }
    }

    /// Everything the tool may clean on request: any non-Mac volume, whatever
    /// the transport. Used by the menu and `bclean volumes`.
    public static func cleanable() -> [Volume] {
        all().filter { $0.isTarget }
    }

    /// What the watcher, `sweep` and the volume menu treat as fair game
    /// without asking. Network shares need an explicitly allowed host.
    public static func targets() -> [Volume] {
        let hosts = NetworkPolicy.allowedHosts
        return all().filter { $0.allowsAutomaticClean(allowedHosts: hosts) }
    }

    public static func volume(containing path: String, in volumes: [Volume]) -> Volume? {
        let target = (path as NSString).standardizingPath
        return volumes
            .filter { target == $0.mountPoint || target.hasPrefix($0.mountPoint + "/") }
            .max { $0.mountPoint.count < $1.mountPoint.count }
    }
}

public enum PathGuard {
    /// Never operate on these even if a rule would match inside them.
    public static let forbidden: [String] = [
        "/System", "/usr", "/bin", "/sbin", "/private", "/Library",
        "/Applications", "/opt", "/cores", "/dev", "/etc", "/var",
    ]

    public static func isForbidden(_ path: String) -> Bool {
        let p = (path as NSString).standardizingPath
        if p == "/" { return true }
        if p == NSHomeDirectory() { return true }
        for root in forbidden where p == root || p.hasPrefix(root + "/") {
            return true
        }
        return false
    }
}
