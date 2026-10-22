import Darwin
import Foundation

public struct ExecResult: Sendable {
    public var removed: Int = 0
    public var removedDirectories: Int = 0
    public var bytes: Int64 = 0
    public var failures: [(path: String, reason: String)] = []
    public var skipped: [String] = []

    public var ok: Bool { failures.isEmpty }

    public func summary(dryRun: Bool = false) -> String {
        var s = dryRun ? "would remove \(removed) items" : "removed \(removed) items"
        if removedDirectories > 0 { s += " (\(removedDirectories) dirs)" }
        s += ", \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
        if !failures.isEmpty { s += ", \(failures.count) failed" }
        if !skipped.isEmpty { s += ", \(skipped.count) skipped" }
        return s
    }

    public init() {}
}

public enum Executor {
    /// Deletes a plan. Assumes the plan was produced by `Scanner` for the same
    /// root, but re-verifies every filesystem assumption anyway: this is the
    /// only code in the project that removes things.
    @discardableResult
    public static func execute(_ plan: Plan,
                               dryRun: Bool = false,
                               log: Log? = nil) -> ExecResult {
        var result = ExecResult()

        let root = (plan.root as NSString).standardizingPath
        guard !PathGuard.isForbidden(root) else {
            result.failures.append((root, "refused: protected path"))
            return result
        }
        guard let rootDev = FSInfo.device(of: root) else {
            result.failures.append((root, "refused: cannot stat root"))
            return result
        }

        // Files first, then directories deepest-first, so removing a parent
        // never turns a child into a spurious ENOENT.
        let files = plan.items.filter { !$0.isDirectory }
        let dirs = plan.items.filter { $0.isDirectory }
            .sorted { $0.path.count > $1.path.count }

        for item in files + dirs {
            let path = item.path
            let parent = (path as NSString).deletingLastPathComponent

            // 1. Everything must still live on the volume we scanned.
            guard let parentDev = FSInfo.device(of: parent), parentDev == rootDev else {
                result.failures.append((path, "skipped: parent is on a different volume"))
                continue
            }

            guard let entry = FSInfo.entry(at: path) else {
                result.skipped.append(path)  // already gone
                continue
            }

            // 2. A directory that became a mount point is not ours to remove.
            if entry.isDirectory && FSInfo.isMountPoint(path) {
                result.failures.append((path, "skipped: is a mount point"))
                continue
            }

            // 3. Never follow a symlink; unlink removes the link itself.
            if entry.isSymlink && item.isDirectory {
                result.failures.append((path, "skipped: symlink"))
                continue
            }

            if dryRun {
                result.removed += 1
                result.bytes += item.bytes
                if item.isDirectory { result.removedDirectories += 1 }
                log?.write("DRY   \(item.ruleID)  \(path)")
                continue
            }

            var errorMessage: String?
            if entry.isDirectory {
                do {
                    try FileManager.default.removeItem(atPath: path)
                    errorMessage = nil
                } catch {
                    errorMessage = error.localizedDescription
                }
            } else {
                if unlink(path) == 0 {
                    errorMessage = nil
                } else {
                    errorMessage = String(cString: strerror(errno))
                }
            }

            if let errorMessage {
                result.failures.append((path, errorMessage))
                log?.write("FAIL  \(item.ruleID)  \(path)  \(errorMessage)")
            } else {
                result.removed += 1
                result.bytes += item.bytes
                if entry.isDirectory { result.removedDirectories += 1 }
                log?.write("DEL   \(item.ruleID)  \(path)")
            }
        }

        log?.write("DONE  \(root)  \(result.summary(dryRun: dryRun))")
        return result
    }
}
