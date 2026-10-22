import Darwin
import Foundation

public struct WalkEntry {
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let isSymlink: Bool
    public let device: dev_t
    public let size: Int64
}

/// Depth-first directory walk built on opendir/readdir.
///
/// `FileManager.enumerator` is not usable here: macOS treats `._*` as an
/// AppleDouble companion of the file it shadows and filters those names out of
/// enumeration entirely. Verified on this machine — a directory containing
/// `thing.txt` and `._thing.txt` enumerates as `["thing.txt"]` through both
/// `enumerator(atPath:)` and `enumerator(at:includingPropertiesForKeys:)`.
/// That is the single most important thing this tool deletes, so the walk has
/// to go through readdir.
public enum Walker {
    public static func walk(root: String,
                            onError: (String) -> Void = { _ in },
                            visit: (WalkEntry) -> Bool) {
        let rootPath = (root as NSString).standardizingPath
        guard let rootDevice = FSInfo.device(of: rootPath),
              let rootStat = FSInfo.entry(at: rootPath),
              rootStat.isDirectory else {
            onError("cannot stat root: \(rootPath)")
            return
        }

        var stack: [String] = [rootPath]

        while let directory = stack.popLast() {
            guard let handle = opendir(directory) else {
                onError("cannot open: \(directory)")
                continue
            }

            var children: [String] = []

            while let raw = readdir(handle) {
                let name = cString(raw)
                if name.isEmpty || name == "." || name == ".." { continue }

                let full = directory.hasSuffix("/") ? directory + name : directory + "/" + name
                guard let stat = FSInfo.entry(at: full) else {
                    onError("cannot stat: \(full)")
                    continue
                }

                let entry = WalkEntry(path: full,
                                      name: name,
                                      isDirectory: stat.isDirectory,
                                      isSymlink: stat.isSymlink,
                                      device: stat.device,
                                      size: stat.isDirectory ? 0 : stat.size)

                // Never cross a mount boundary.
                if entry.isDirectory && entry.device != rootDevice { continue }

                let descend = visit(entry)
                if descend && entry.isDirectory { children.append(full) }
            }

            closedir(handle)
            stack.append(contentsOf: children.reversed())
        }
    }

    private static func cString(_ entry: UnsafeMutablePointer<dirent>) -> String {
        var name = entry.pointee.d_name
        return withUnsafeBytes(of: &name) { raw -> String in
            guard let base = raw.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }
}
