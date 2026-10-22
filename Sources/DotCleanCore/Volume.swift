import Darwin
import Foundation

public struct Volume: Sendable, Codable, Equatable {
    public let mountPoint: String
    public let fsType: String
    public let isLocal: Bool
    public let isRemovable: Bool
    public let isInternal: Bool

    public init(mountPoint: String,
                fsType: String,
                isLocal: Bool,
                isRemovable: Bool,
                isInternal: Bool) {
        self.mountPoint = mountPoint
        self.fsType = fsType
        self.isLocal = isLocal
        self.isRemovable = isRemovable
        self.isInternal = isInternal
    }

    /// Filesystems where `._`/`.DS_Store` are native and must be left alone.
    public var isMacFormat: Bool {
        ["apfs", "hfs", "hfsx"].contains(fsType.lowercased())
    }

    public var isTarget: Bool { !isMacFormat }

    public var name: String {
        mountPoint == "/" ? "Macintosh HD" : (mountPoint as NSString).lastPathComponent
    }

    public var summary: String {
        let where_ = isLocal ? "local" : "network"
        return "\(name) — \(fsType), \(where_)"
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
                isLocal: values?.volumeIsLocal ?? true,
                isRemovable: values?.volumeIsRemovable ?? false,
                isInternal: values?.volumeIsInternal ?? false
            )
        }
        .sorted { $0.mountPoint.localizedStandardCompare($1.mountPoint) == .orderedAscending }
    }

    public static func targets() -> [Volume] {
        all().filter { $0.isTarget }
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
