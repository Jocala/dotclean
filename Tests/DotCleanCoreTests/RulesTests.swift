import XCTest
@testable import DotCleanCore

final class RulesTests: XCTestCase {
    func testExactNameMatchesCaseInsensitively() {
        let rule = Rule(id: "dsstore", label: "", match: .name(".DS_Store"), target: .any)
        XCTAssertTrue(rule.applies(to: ".DS_Store", isDirectory: false))
        XCTAssertTrue(rule.applies(to: ".ds_store", isDirectory: false))
        XCTAssertFalse(rule.applies(to: ".DS_Store.bak", isDirectory: false))
    }

    func testPrefixMatchesAppleDouble() {
        let rule = Rule(id: "appledouble", label: "", match: .prefix("._"), target: .file)
        XCTAssertTrue(rule.applies(to: "._report.pdf", isDirectory: false))
        XCTAssertFalse(rule.applies(to: "._folder", isDirectory: true))
        XCTAssertFalse(rule.applies(to: "report.pdf", isDirectory: false))
    }

    func testDirectoryTargetRejectsFiles() {
        let rule = Rule(id: "trashes", label: "", match: .name(".Trashes"), target: .directory)
        XCTAssertTrue(rule.applies(to: ".Trashes", isDirectory: true))
        XCTAssertFalse(rule.applies(to: ".Trashes", isDirectory: false))
    }

    func testGlob() {
        XCTAssertTrue(Rule.glob("*.blah", "report.blah"))
        XCTAssertTrue(Rule.glob("._*", "._x"))
        XCTAssertTrue(Rule.glob("*", "anything"))
        XCTAssertFalse(Rule.glob("*.blah", "report.bla"))
        XCTAssertFalse(Rule.glob("a*b*c", "ab"))
        XCTAssertTrue(Rule.glob("a*b*c", "aXXbYYc"))
    }

    func testScopeSeparation() {
        let watcherRules = RuleSet.standard.active(in: .watcher).map(\.id)
        let adhocRules = RuleSet.standard.active(in: .adhoc).map(\.id)

        XCTAssertTrue(watcherRules.contains("dsstore"))
        XCTAssertTrue(watcherRules.contains("appledouble"))
        XCTAssertFalse(watcherRules.contains("trashes"))
        XCTAssertFalse(watcherRules.contains("spotlight"))

        XCTAssertTrue(adhocRules.contains("trashes"))
        XCTAssertTrue(adhocRules.contains("spotlight"))
        XCTAssertTrue(adhocRules.contains("dsstore"))
    }

    func testProtectedExtensions() {
        let rules = RuleSet.standard
        XCTAssertTrue(rules.isProtected("._GillSans.ttf"))
        XCTAssertTrue(rules.isProtected("._artwork.eps"))
        XCTAssertFalse(rules.isProtected("._report.pdf"))
        XCTAssertFalse(rules.isProtected("._noext"))
    }

    func testPathGuard() {
        XCTAssertTrue(PathGuard.isForbidden("/"))
        XCTAssertTrue(PathGuard.isForbidden("/System/Library"))
        XCTAssertTrue(PathGuard.isForbidden("/usr/local"))
        XCTAssertTrue(PathGuard.isForbidden(NSHomeDirectory()))
        XCTAssertFalse(PathGuard.isForbidden("/Volumes/storage/projects"))
        XCTAssertFalse(PathGuard.isForbidden(NSHomeDirectory() + "/Desktop"))
    }

    func testFilesystemTypeOfRootIsAPFS() {
        let type = FSInfo.type(of: "/")
        XCTAssertNotNil(type)
        XCTAssertFalse(Volume(mountPoint: "/", fsType: type ?? "", isLocal: true,
                              isRemovable: false, isInternal: true).isTarget)
    }

    func testVolumeContainmentPicksLongestPrefix() {        let volumes = [
            Volume(mountPoint: "/Volumes/a", fsType: "exfat", isLocal: true, isRemovable: true, isInternal: false),
            Volume(mountPoint: "/Volumes/a/nested", fsType: "smbfs", isLocal: false, isRemovable: false, isInternal: false),
        ]
        XCTAssertEqual(VolumeList.volume(containing: "/Volumes/a/nested/x/y", in: volumes)?.mountPoint,
                       "/Volumes/a/nested")
        XCTAssertEqual(VolumeList.volume(containing: "/Volumes/a/other", in: volumes)?.mountPoint,
                       "/Volumes/a")
        XCTAssertNil(VolumeList.volume(containing: "/Users", in: volumes))
    }
}
