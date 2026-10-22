import Darwin
import Foundation

public struct MatchItem: Sendable, Codable, Equatable {
    public let path: String
    public let name: String
    public let ruleID: String
    public let isDirectory: Bool
    public let bytes: Int64

    public init(path: String, name: String, ruleID: String, isDirectory: Bool, bytes: Int64) {
        self.path = path
        self.name = name
        self.ruleID = ruleID
        self.isDirectory = isDirectory
        self.bytes = bytes
    }
}

public struct RuleTally: Sendable, Codable, Equatable {
    public let ruleID: String
    public let label: String
    public var count: Int
    public var bytes: Int64
    public var directories: Int

    public init(ruleID: String, label: String, count: Int = 0, bytes: Int64 = 0, directories: Int = 0) {
        self.ruleID = ruleID
        self.label = label
        self.count = count
        self.bytes = bytes
        self.directories = directories
    }
}

public struct Plan: Sendable, Codable {
    public let root: String
    public let volume: Volume
    public let items: [MatchItem]
    /// Matched, but deliberately skipped (protected resource-fork extension).
    public let protectedItems: [String]
    public let errors: [String]
    public let tallies: [RuleTally]

    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    public var isEmpty: Bool { items.isEmpty }

    public init(root: String,
                volume: Volume,
                items: [MatchItem],
                protectedItems: [String],
                errors: [String],
                tallies: [RuleTally]) {
        self.root = root
        self.volume = volume
        self.items = items
        self.protectedItems = protectedItems
        self.errors = errors
        self.tallies = tallies
    }
}

public struct Scanner {
    public var rules: RuleSet
    public var scope: RuleScope

    public init(rules: RuleSet = .standard, scope: RuleScope = .adhoc) {
        self.rules = rules
        self.scope = scope
    }

    public func scan(root: URL) -> Plan {
        let rootPath = (root.path as NSString).standardizingPath
        let volume = Volume(mountPoint: rootPath,
                            fsType: FSInfo.type(of: rootPath) ?? "unknown",
                            isLocal: true,
                            isRemovable: false,
                            isInternal: false)

        var items: [MatchItem] = []
        var protectedItems: [String] = []
        var errors: [String] = []
        var order: [String] = []
        var tallies: [String: RuleTally] = [:]

        let labels = Dictionary(uniqueKeysWithValues: rules.rules.map { ($0.id, $0.label) })
        let active = rules.active(in: scope)

        Walker.walk(root: rootPath, onError: { errors.append($0) }) { entry in
            guard let rule = active.first(where: {
                $0.applies(to: entry.name, isDirectory: entry.isDirectory)
            }) else {
                return true
            }

            if rule.id == "appledouble" && rules.isProtected(entry.name) {
                protectedItems.append(entry.path)
                return true
            }

            items.append(MatchItem(path: entry.path,
                                   name: entry.name,
                                   ruleID: rule.id,
                                   isDirectory: entry.isDirectory,
                                   bytes: entry.size))

            if tallies[rule.id] == nil {
                tallies[rule.id] = RuleTally(ruleID: rule.id, label: labels[rule.id] ?? rule.id)
                order.append(rule.id)
            }
            tallies[rule.id]?.count += 1
            tallies[rule.id]?.bytes += entry.size
            if entry.isDirectory { tallies[rule.id]?.directories += 1 }

            // Don't descend into something we are about to remove wholesale.
            return !entry.isDirectory
        }

        return Plan(root: rootPath,
                    volume: volume,
                    items: items,
                    protectedItems: protectedItems,
                    errors: errors,
                    tallies: order.compactMap { tallies[$0] })
    }
}

extension Plan {
    public func prettyText(samples: Int = 0) -> String {
        var out = ""
        out += "\(root)\n"
        out += "  filesystem: \(volume.fsType)"
        out += volume.isMacFormat ? " (Mac format — skipped by default)" : " (non-Mac)"
        out += "\n"

        if tallies.isEmpty {
            out += "  nothing to clean\n"
        } else {
            let width = max(26, tallies.map { $0.label.count }.max() ?? 26)
            for tally in tallies {
                let label = tally.label.padding(toLength: width, withPad: " ", startingAt: 0)
                let count = String(tally.count).leftPadded(to: 8)
                let size = tally.bytes > 0
                    ? ByteCountFormatter.string(fromByteCount: tally.bytes, countStyle: .file)
                    : ""
                out += "  \(label)\(count)  \(size)\n"
            }
            out += "  \(String(repeating: "-", count: width + 14))\n"
            let label = "total".padding(toLength: width, withPad: " ", startingAt: 0)
            out += "  \(label)\(String(items.count).leftPadded(to: 8))  "
            out += ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file) + "\n"
        }

        if !protectedItems.isEmpty {
            out += "  protected (resource-fork file types kept): \(protectedItems.count)\n"
        }

        if samples > 0 && !items.isEmpty {
            out += "\n"
            for item in items.prefix(samples) {
                out += "  \(item.isDirectory ? "d" : "-") \(item.path)\n"
            }
            if items.count > samples {
                out += "  … \(items.count - samples) more\n"
            }
        }

        if !errors.isEmpty {
            out += "\n  errors:\n"
            for error in errors.prefix(10) { out += "    \(error)\n" }
            if errors.count > 10 { out += "    … \(errors.count - 10) more\n" }
        }
        return out
    }
}

extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
