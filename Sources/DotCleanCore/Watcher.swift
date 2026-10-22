import AppKit
import CoreServices
import Foundation

/// Live cleaner. One FSEvents stream rooted at "/", filtered by mount point, so
/// mounting a volume never requires rebuilding the stream.
///
/// FSEvents is lossy under load: it will coalesce and, when the kernel queue
/// overflows, emit MustScanSubDirs / UserDropped / KernelDropped instead of the
/// individual events. Those are treated as "re-scan this subtree", never
/// ignored — a watcher that reports healthy while missing everything is worse
/// than no watcher at all.
public final class Watcher: @unchecked Sendable {
    public struct Stats: Sendable {
        public var deleted = 0
        public var batches = 0
        public var dropRecoveries = 0
        public var loopsSuppressed = 0
    }

    public private(set) var stats = Stats()
    public var onDelete: ((String) -> Void)?

    private let rules: RuleSet
    private let log: Log?
    private let latency: CFTimeInterval
    private let queue = DispatchQueue(label: "com.jocala.dotclean.watcher")

    private var stream: FSEventStreamRef?
    private var volumes: [Volume] = []
    private var recentDeletes: [String: (count: Int, firstSeen: TimeInterval)] = [:]
    private var suppressed: Set<String> = []
    private var pendingSweep: Set<String> = []
    private var sweepWork: DispatchWorkItem?
    private var observerTokens: [NSObjectProtocol] = []
    private let maxDeletesPerBatch = 5_000

    public init(rules: RuleSet = .standard,
                latency: Double = 0.25,
                log: Log? = nil) {
        self.rules = rules
        self.latency = latency
        self.log = log
    }

    deinit { stop() }

    public var isRunning: Bool { stream != nil }

    public func start() {
        queue.async { [weak self] in
            guard let self, self.stream == nil else { return }
            self.refreshVolumesLocked()
            self.startStreamLocked()
            self.observeMounts()
        }
    }

    public func stop() {
        queue.sync {
            stopStreamLocked()
            for token in observerTokens {
                NSWorkspace.shared.notificationCenter.removeObserver(token)
            }
            observerTokens.removeAll()
        }
    }

    public func refreshVolumes() {
        queue.async { [weak self] in self?.refreshVolumesLocked() }
    }

    /// Full scan of every non-Mac volume using the live rule scope. Manual only:
    /// walking network shares on a timer is hostile.
    public func sweepNow() {
        queue.async { [weak self] in
            guard let self else { return }
            for volume in self.volumes {
                let plan = Scanner(rules: self.rules, scope: .watcher)
                    .scan(root: URL(fileURLWithPath: volume.mountPoint))
                guard !plan.isEmpty else { continue }
                let result = Executor.execute(plan, dryRun: false, log: self.log)
                self.stats.deleted += result.removed
                if result.removed > 0 {
                    self.log?.write("SWEEP \(volume.mountPoint) \(result.summary())")
                }
            }
        }
    }

    // MARK: - Stream

    private func startStreamLocked() {
        guard stream == nil else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagWatchRoot
        )

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            dotcleanFSEventsCallback,
            &context,
            ["/"] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            log?.write("ERROR could not create FSEvents stream")
            return
        }

        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            log?.write("ERROR could not start FSEvents stream")
            return
        }
        stream = created
        log?.write("WATCH started latency=\(latency)s volumes=\(volumes.count)")
    }

    private func stopStreamLocked() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        log?.write("WATCH stopped")
    }

    private func observeMounts() {
        guard observerTokens.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            let token = center.addObserver(forName: name, object: nil, queue: nil) { [weak self] (_: Notification) in
                self?.queue.async { self?.refreshVolumesLocked() }
            }
            observerTokens.append(token)
        }
    }

    private func refreshVolumesLocked() {
        volumes = VolumeList.targets()
    }

    // MARK: - Events

    fileprivate func handle(paths: [String], flags: UnsafePointer<FSEventStreamEventFlags>, count: Int) {
        stats.batches += 1
        var candidates: [String] = []
        var seen = Set<String>()
        var needsRecovery = false

        for index in 0..<min(count, paths.count) {
            let flag = flags[index]
            let dropped = flag & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0
                || flag & FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped) != 0
                || flag & FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped) != 0

            if dropped {
                needsRecovery = true
                let path = paths[index]
                if let volume = VolumeList.volume(containing: path, in: volumes) {
                    pendingSweep.insert(volume.mountPoint)
                }
                continue
            }

            let path = paths[index]
            if seen.insert(path).inserted { candidates.append(path) }
        }

        if needsRecovery {
            stats.dropRecoveries += 1
            scheduleRecoverySweep()
        }

        guard !candidates.isEmpty else { return }
        let limit = min(candidates.count, maxDeletesPerBatch)
        for path in candidates.prefix(limit) {
            handleSingle(path: path)
        }
        if candidates.count > limit {
            // Batch was pathological: fall back to a subtree scan for the rest.
            for volume in volumes { pendingSweep.insert(volume.mountPoint) }
            scheduleRecoverySweep()
        }
    }

    private func handleSingle(path: String) {
        guard VolumeList.volume(containing: path, in: volumes) != nil else { return }
        guard !PathGuard.isForbidden(path) else { return }
        if suppressed.contains(path) { return }

        let name = (path as NSString).lastPathComponent
        guard let entry = FSInfo.entry(at: path) else { return }
        guard let rule = rules.firstMatch(for: name, isDirectory: entry.isDirectory, in: .watcher) else {
            return
        }
        if rule.id == "appledouble" && rules.isProtected(name) { return }

        // Fight-loop guard: some apps recreate `._` the instant it is removed.
        // Delete a handful of times, then stop touching that path for this session.
        let now = Date().timeIntervalSince1970
        if var record = recentDeletes[path] {
            if now - record.firstSeen > 60 {
                record = (1, now)
            } else {
                record.count += 1
            }
            recentDeletes[path] = record
            if record.count > 5 {
                suppressed.insert(path)
                stats.loopsSuppressed += 1
                log?.write("SUPPRESS loop guard \(path)")
                return
            }
        } else {
            recentDeletes[path] = (1, now)
        }

        if entry.isDirectory {
            guard !FSInfo.isMountPoint(path) else { return }
            do {
                try FileManager.default.removeItem(atPath: path)
            } catch {
                log?.write("FAIL  \(rule.id)  \(path)  \(error.localizedDescription)")
                return
            }
        } else {
            guard unlink(path) == 0 else {
                log?.write("FAIL  \(rule.id)  \(path)  \(String(cString: strerror(errno)))")
                return
            }
        }

        stats.deleted += 1
        log?.write("WATCH \(rule.id)  \(path)")
        onDelete?(path)
    }

    private func scheduleRecoverySweep() {
        sweepWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.pendingSweep.isEmpty else { return }
            let roots = self.pendingSweep
            self.pendingSweep.removeAll()
            for root in roots {
                let plan = Scanner(rules: self.rules, scope: .watcher)
                    .scan(root: URL(fileURLWithPath: root))
                guard !plan.isEmpty else { continue }
                let result = Executor.execute(plan, dryRun: false, log: self.log)
                self.stats.deleted += result.removed
                if result.removed > 0 {
                    self.log?.write("RECOVER \(root) \(result.summary())")
                }
            }
        }
        sweepWork = work
        queue.asyncAfter(deadline: .now() + 2.0, execute: work)
    }
}

/// FSEvents requires a C function pointer, so this cannot capture context.
private func dotcleanFSEventsCallback(
    _ streamRef: ConstFSEventStreamRef,
    _ info: UnsafeMutableRawPointer?,
    _ numEvents: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else { return }
    let watcher = Unmanaged<Watcher>.fromOpaque(info).takeUnretainedValue()

    let array = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray
    let paths = array.compactMap { $0 as? String }
    watcher.handle(paths: paths, flags: eventFlags, count: numEvents)
}
