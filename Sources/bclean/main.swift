import DotCleanCore
import Foundation

let toolVersion = "1.0"

// MARK: - Arguments

struct Args {
    var command = ""
    var path: String?
    var scope: RuleScope = .adhoc
    var json = false
    var dryRun = false
    var assumeYes = false
    var eject = false
    var forceEject = false
    var allowMac = false
    var samples = 0
    var seconds = 0
}

func usage() -> String {
    """
    dotclean \(toolVersion) — remove macOS metadata from non-Mac volumes

    USAGE
      bclean volumes [--json]
      bclean scan  <path> [--samples N] [--json] [--watcher-only] [--mac]
      bclean clean <path> [--yes] [--dry-run] [--json]
                           [--watcher-only] [--mac] [--eject] [--force-eject]
      bclean sweep [--dry-run] [--watcher-only]
      bclean watch [--seconds N]
      bclean rules
      bclean log

    NOTES
      clean is dry-run by default; --yes actually deletes.
      --watcher-only limits to rules the live watcher may fire (no .Trashes,
      .Spotlight-V100, .fseventsd, .TemporaryItems, $Recycle.bin, System Volume
      Information).
      Mac-formatted volumes (APFS/HFS) are refused unless --mac is given.
    """
}

func parse(_ raw: [String]) -> Args {
    var args = Args()
    var positional: [String] = []
    var index = 0

    while index < raw.count {
        let arg = raw[index]
        switch arg {
        case "--json": args.json = true
        case "--dry-run", "-n": args.dryRun = true
        case "--yes", "-y": args.assumeYes = true
        case "--eject": args.eject = true
        case "--force-eject": args.eject = true; args.forceEject = true
        case "--mac": args.allowMac = true
        case "--watcher-only": args.scope = .watcher
        case "--adhoc": args.scope = .adhoc
        case "--samples":
            index += 1
            args.samples = index < raw.count ? Int(raw[index]) ?? 0 : 0
        case "--seconds":
            index += 1
            args.seconds = index < raw.count ? Int(raw[index]) ?? 0 : 0
        case "-h", "--help":
            print(usage())
            exit(0)
        case "--version":
            print(toolVersion)
            exit(0)
        default:
            if arg.hasPrefix("-") {
                FileHandle.standardError.write(Data("unknown option: \(arg)\n".utf8))
                exit(2)
            }
            positional.append(arg)
        }
        index += 1
    }

    args.command = positional.first ?? ""
    if positional.count > 1 { args.path = positional[1] }
    return args
}

// MARK: - Output

struct PlanJSON: Encodable {
    let root: String
    let fsType: String
    let isMacFormat: Bool
    let itemCount: Int
    let totalBytes: Int64
    let tallies: [RuleTally]
    let protectedCount: Int
    let errors: [String]
    let items: [MatchItem]
}

struct ExecJSON: Encodable {
    let root: String
    let dryRun: Bool
    let removed: Int
    let removedDirectories: Int
    let bytes: Int64
    let failed: [Failure]
    let skipped: Int

    struct Failure: Encodable {
        let path: String
        let reason: String
    }
}

func emit<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) {
        print(text)
    }
}

func die(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("bclean: \(message)\n".utf8))
    exit(code)
}

func volume(for path: String) -> Volume {
    let standardized = (path as NSString).standardizingPath
    return Volume(mountPoint: standardized,
                  fsType: FSInfo.type(of: standardized) ?? "unknown",
                  isLocal: true,
                  isRemovable: false,
                  isInternal: false)
}

/// Refuses the two cases that actually matter: our own system paths, and
/// Mac-formatted volumes where deleting `._`/`.DS_Store` is destructive.
func validate(path: String, allowMac: Bool) -> Volume {
    let standardized = (path as NSString).standardizingPath
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: standardized, isDirectory: &isDirectory) else {
        die("no such path: \(standardized)", code: 2)
    }
    if PathGuard.isForbidden(standardized) {
        die("refusing: \(standardized) is a protected system path", code: 3)
    }
    let volume = volume(for: standardized)
    if volume.isMacFormat && !allowMac {
        die("refusing: \(volume.fsType) is a Mac format. Pass --mac to override.", code: 3)
    }
    if !volume.isTarget && !allowMac {
        die("refusing: \(volume.fsType) is not a non-Mac format. Pass --mac to override.", code: 3)
    }
    return volume
}

// MARK: - Main

let args = parse(Array(CommandLine.arguments.dropFirst()))
let log = Log()
let rules = RuleSet.standard

switch args.command {
case "volumes":
    let volumes = VolumeList.all()
    if args.json {
        struct VolumesJSON: Encodable {
            let volumes: [Volume]
            let targets: [String]
        }
        emit(VolumesJSON(volumes: volumes, targets: volumes.filter { $0.isTarget }.map { $0.mountPoint }))
    } else {
        for volume in volumes {
            let mark = volume.isTarget ? "*" : " "
            print("\(mark) \(volume.mountPoint.padding(toLength: 34, withPad: " ", startingAt: 0)) "
                  + "\(volume.fsType.padding(toLength: 10, withPad: " ", startingAt: 0)) "
                  + (volume.isMacFormat ? "mac" : "non-mac"))
        }
        print("\n* = cleanable")
    }

case "rules":
    for rule in rules.rules {
        let scope = rule.scope == .both ? "live+adhoc" : (rule.scope.contains(.watcher) ? "live" : "adhoc-only")
        print(rule.id.padding(toLength: 16, withPad: " ", startingAt: 0)
              + rule.label.padding(toLength: 34, withPad: " ", startingAt: 0)
              + rule.target.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)
              + scope)
    }
    print("\nprotected extensions: \(rules.protectedExtensions.sorted().joined(separator: " "))")

case "log":
    print(log?.path ?? "logging unavailable")

case "watch":
    let watcher = Watcher(log: log)
    watcher.onDelete = { print("deleted \($0)") }
    watcher.start()
    let targets = VolumeList.targets().map { $0.mountPoint }
    print("watching \(targets.count) non-Mac volume(s): \(targets.joined(separator: ", "))")
    if args.seconds > 0 {
        Thread.sleep(forTimeInterval: TimeInterval(args.seconds))
        watcher.stop()
        print("stopped after \(args.seconds)s — \(watcher.stats.deleted) item(s) removed")
    } else {
        print("Ctrl-C to stop")
        dispatchMain()
    }

case "scan", "clean", "sweep":
    var roots: [String] = []
    if args.command == "sweep" {
        roots = VolumeList.targets().map { $0.mountPoint }
        if roots.isEmpty { die("no non-Mac volumes mounted", code: 1) }
    } else {
        guard let path = args.path else { die("missing <path>") }
        _ = validate(path: path, allowMac: args.allowMac)
        roots = [(path as NSString).standardizingPath]
    }

    if args.command == "scan" {
        for root in roots {
            let plan = Scanner(rules: rules, scope: args.scope)
                .scan(root: URL(fileURLWithPath: root))
            if args.json {
                emit(PlanJSON(root: plan.root,
                              fsType: plan.volume.fsType,
                              isMacFormat: plan.volume.isMacFormat,
                              itemCount: plan.items.count,
                              totalBytes: plan.totalBytes,
                              tallies: plan.tallies,
                              protectedCount: plan.protectedItems.count,
                              errors: plan.errors,
                              items: plan.items))
            } else {
                print(plan.prettyText(samples: args.samples))
            }
        }
    } else {
        var removed = 0
        var failed = 0
        let dryRun = args.command == "scan" || (!args.assumeYes && args.command == "clean") || args.dryRun

        for root in roots {
            let plan = Scanner(rules: rules, scope: args.scope)
                .scan(root: URL(fileURLWithPath: root))

            if args.command == "clean" && !args.json {
                print(plan.prettyText(samples: args.samples))
            }

            if plan.isEmpty {
                if !args.json && args.command == "sweep" {
                    print("\(root): nothing to clean")
                }
            } else {
                if dryRun && args.command == "clean" && !args.json {
                    print("dry run — pass --yes to delete")
                }

                let result = Executor.execute(plan, dryRun: dryRun, log: log)
                removed += result.removed
                failed += result.failures.count

                if args.json {
                    emit(ExecJSON(root: plan.root,
                                  dryRun: dryRun,
                                  removed: result.removed,
                                  removedDirectories: result.removedDirectories,
                                  bytes: result.bytes,
                                  failed: result.failures.map { .init(path: $0.path, reason: $0.reason) },
                                  skipped: result.skipped.count))
                } else {
                    print(result.summary(dryRun: dryRun))
                    for failure in result.failures.prefix(20) {
                        print("  failed: \(failure.path) — \(failure.reason)")
                    }
                }
            }

            if args.eject && !dryRun {
                switch Disk.eject(path: root, force: args.forceEject) {
                case .success:
                    if !args.json { print("ejected \(root)") }
                case .failure(let message):
                    FileHandle.standardError.write(Data("eject failed: \(message)\n".utf8))
                    failed += 1
                }
            }
        }
        exit(failed > 0 ? 1 : 0)
    }

case "":
    print(usage())

default:
    FileHandle.standardError.write(Data("unknown command: \(args.command)\n\n".utf8))
    print(usage())
    exit(2)
}
