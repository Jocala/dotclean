import Foundation
import os

/// Append-only log at ~/Library/Logs/DotClean/dotclean.log, plus os_log.
/// Every deletion and refusal is recorded; the watcher's own count is derived
/// from this so the ad-hoc preview can show what it already handled.
public final class Log: @unchecked Sendable {
    public let path: String
    private let handle: FileHandle?
    private let queue = DispatchQueue(label: "com.jocala.dotclean.log")
    private let logger = Logger(subsystem: "com.jocala.dotclean", category: "clean")

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DotClean", isDirectory: true)
    }

    public init?(directory: URL = Log.defaultDirectory) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("dotclean.log")
        self.path = file.path
        if !fm.fileExists(atPath: file.path) {
            fm.createFile(atPath: file.path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: file.path) else { return nil }
        handle.seekToEndOfFile()
        self.handle = handle
    }

    public func write(_ message: String) {
        let stamp = Log.formatter.string(from: Date())
        let line = "\(stamp) \(message)\n"
        logger.debug("\(message, privacy: .public)")
        queue.async { [handle] in
            handle?.write(Data(line.utf8))
        }
    }

    public static var logDirectory: URL { defaultDirectory }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
