import Foundation

/// Where a rule is allowed to fire.
///
/// Some names are safe to delete the instant they appear (`.DS_Store`, `._*`).
/// Others are live system-owned directories (`.fseventsd`, `.Spotlight-V100`,
/// `.Trashes`, `.TemporaryItems`) which churn Finder and can retrigger Spotlight
/// if they are removed while the volume is mounted. Those are ad-hoc only.
public struct RuleScope: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let watcher = RuleScope(rawValue: 1 << 0)
    public static let adhoc   = RuleScope(rawValue: 1 << 1)
    public static let both: RuleScope = [.watcher, .adhoc]
}

public enum RuleMatch: Sendable, Equatable {
    case name(String)
    case prefix(String)
    case suffix(String)
    case glob(String)
}

public enum RuleTarget: String, Sendable, Equatable {
    case file
    case directory
    case any
}

public struct Rule: Sendable, Identifiable, Equatable {
    public let id: String
    public let label: String
    public let match: RuleMatch
    public let target: RuleTarget
    public let scope: RuleScope
    public let enabled: Bool

    public init(id: String,
                label: String,
                match: RuleMatch,
                target: RuleTarget = .any,
                scope: RuleScope = .both,
                enabled: Bool = true) {
        self.id = id
        self.label = label
        self.match = match
        self.target = target
        self.scope = scope
        self.enabled = enabled
    }

    public func applies(to name: String, isDirectory: Bool) -> Bool {
        switch target {
        case .file where isDirectory: return false
        case .directory where !isDirectory: return false
        default: break
        }

        switch match {
        case .name(let expected):
            return name.compare(expected, options: [.caseInsensitive, .literal]) == .orderedSame
        case .prefix(let p):
            return name.hasPrefix(p)
        case .suffix(let s):
            return name.lowercased().hasSuffix(s.lowercased())
        case .glob(let g):
            return Self.glob(g, name)
        }
    }

    /// Single-wildcard matcher (`*` only). Iterative, no backtracking blowup.
    static func glob(_ pattern: String, _ name: String) -> Bool {
        let p = Array(pattern)
        let n = Array(name)
        var pi = 0, ni = 0, star = -1, mark = 0

        while ni < n.count {
            if pi < p.count && p[pi] == "*" {
                star = pi
                pi += 1
                mark = ni
            } else if pi < p.count && p[pi] == n[ni] {
                pi += 1
                ni += 1
            } else if star >= 0 {
                pi = star + 1
                mark += 1
                ni = mark
            } else {
                return false
            }
        }
        while pi < p.count && p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}

public struct RuleSet: Sendable {
    public var rules: [Rule]
    /// `._Foo.ttf` can carry the actual glyph data. Never delete those.
    public var protectedExtensions: Set<String>

    public init(rules: [Rule], protectedExtensions: Set<String>) {
        self.rules = rules
        self.protectedExtensions = protectedExtensions
    }

    public static let standard = RuleSet(
        rules: Rule.builtIn,
        protectedExtensions: Rule.builtInProtectedExtensions
    )

    public func active(in scope: RuleScope) -> [Rule] {
        rules.filter { $0.enabled && !$0.scope.intersection(scope).isEmpty }
    }

    public func firstMatch(for name: String, isDirectory: Bool, in scope: RuleScope) -> Rule? {
        for rule in active(in: scope) where rule.applies(to: name, isDirectory: isDirectory) {
            return rule
        }
        return nil
    }

    public func isProtected(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return !ext.isEmpty && protectedExtensions.contains(ext)
    }
}

extension Rule {
    public static let builtInProtectedExtensions: Set<String> = [
        "ttf", "otf", "ttc", "dfont", "eps", "ps", "ai", "indd", "qxd",
    ]

    public static let builtIn: [Rule] = [
        Rule(id: "appledouble",
             label: "._ AppleDouble files",
             match: .prefix("._"),
             target: .file,
             scope: .both),

        Rule(id: "dsstore",
             label: ".DS_Store",
             match: .name(".DS_Store"),
             target: .any,
             scope: .both),

        Rule(id: "apdisk",
             label: ".apdisk",
             match: .name(".apdisk"),
             target: .file,
             scope: .both),

        Rule(id: "volumeicon",
             label: ".VolumeIcon.icns",
             match: .name(".VolumeIcon.icns"),
             target: .file,
             scope: .both),

        Rule(id: "thumbsdb",
             label: "Thumbs.db (Windows)",
             match: .name("Thumbs.db"),
             target: .file,
             scope: .both),

        Rule(id: "desktopini",
             label: "desktop.ini (Windows)",
             match: .name("desktop.ini"),
             target: .file,
             scope: .both),

        Rule(id: "appledouble-dir",
             label: ".AppleDouble folders",
             match: .name(".AppleDouble"),
             target: .directory,
             scope: .both),

        Rule(id: "macosx-dir",
             label: "__MACOSX folders",
             match: .name("__MACOSX"),
             target: .directory,
             scope: .both),

        // Ad-hoc only: live, system-owned, recreated while mounted.
        Rule(id: "fseventsd",
             label: ".fseventsd",
             match: .name(".fseventsd"),
             target: .directory,
             scope: .adhoc),

        Rule(id: "spotlight",
             label: ".Spotlight-V100",
             match: .name(".Spotlight-V100"),
             target: .directory,
             scope: .adhoc),

        Rule(id: "temporaryitems",
             label: ".TemporaryItems",
             match: .name(".TemporaryItems"),
             target: .directory,
             scope: .adhoc),

        Rule(id: "trashes",
             label: ".Trashes",
             match: .name(".Trashes"),
             target: .directory,
             scope: .adhoc),

        Rule(id: "recyclebin",
             label: "$Recycle.bin (Windows)",
             match: .name("$Recycle.bin"),
             target: .directory,
             scope: .adhoc),

        Rule(id: "sysvolinfo",
             label: "System Volume Information (Windows)",
             match: .name("System Volume Information"),
             target: .directory,
             scope: .adhoc),
    ]
}
