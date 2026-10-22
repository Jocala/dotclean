import Foundation

public struct DiskError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public enum Disk {
    @discardableResult
    private static func run(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func unmount(path: String, force: Bool = false) -> Result<Void, DiskError> {
        var args = ["unmount"]
        if force { args.append("force") }
        args.append(path)
        let result = run("/usr/sbin/diskutil", args)
        if result.status == 0 { return .success(()) }

        // Network shares are not always owned by diskutil.
        let fallback = run("/sbin/umount", force ? ["-f", path] : [path])
        if fallback.status == 0 { return .success(()) }

        let message = result.output.isEmpty ? fallback.output : result.output
        return .failure(DiskError(message.isEmpty ? "unmount failed" : message))
    }

    private static func deviceIdentifier(for path: String) -> String? {
        let result = run("/usr/sbin/diskutil", ["info", "-plist", path])
        guard result.status == 0,
              let data = result.output.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        return plist["DeviceIdentifier"] as? String
    }

    /// `diskutil eject` both unmounts and detaches. The mount point is resolved
    /// to a device identifier first, because ejecting by path fails as soon as
    /// the unmount takes the path away.
    public static func eject(path: String, force: Bool = false) -> Result<Void, DiskError> {
        let target = deviceIdentifier(for: path) ?? path

        var args = ["eject"]
        if force { args.append("force") }
        args.append(target)

        let first = run("/usr/sbin/diskutil", args)
        if first.status == 0 { return .success(()) }

        // Retry the long way: explicit unmount, then detach by device.
        if case .failure(let error) = unmount(path: path, force: force) {
            return .failure(DiskError(first.output.isEmpty ? error.message : first.output))
        }

        var retryArgs = ["eject"]
        if force { retryArgs.append("force") }
        retryArgs.append(target)
        let retry = run("/usr/sbin/diskutil", retryArgs)
        if retry.status == 0 { return .success(()) }

        return .failure(DiskError(retry.output.isEmpty
            ? "unmounted but could not detach \(target)"
            : retry.output))
    }
}
