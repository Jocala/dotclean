import XCTest
@testable import DotCleanCore

/// The whole reason this project uses readdir instead of FileManager.
final class WalksTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        // Not /var/folders: PathGuard refuses system temp areas, and the
        // executor tests need a root it will actually operate on.
        root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches/dotclean-tests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try write("hello", to: "report.txt")
        try write("a", to: "._report.txt")
        try write("b", to: ".DS_Store")
        try write("c", to: "._Protected.ttf")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"),
                                                withIntermediateDirectories: true)
        try write("d", to: "sub/._nested.bin")
        try write("e", to: "sub/real.bin")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ contents: String, to relative: String) throws {
        try contents.data(using: .utf8)?
            .write(to: root.appendingPathComponent(relative))
    }

    /// Documents the Foundation behaviour that forced the readdir walker.
    func testFoundationEnumeratorHidesAppleDouble() throws {
        var names: [String] = []
        if let enumerator = FileManager.default.enumerator(atPath: root.path) {
            for case let name as String in enumerator { names.append(name) }
        }

        XCTAssertTrue(names.contains("report.txt"))
        XCTAssertTrue(names.contains(".DS_Store"))
        XCTAssertFalse(names.contains("._report.txt"),
                       "Foundation is expected to hide AppleDouble companions")
        XCTAssertFalse(names.contains("sub/._nested.bin"))
    }

    func testWalkerSeesAppleDouble() {
        var visited: [String] = []
        Walker.walk(root: root.path) { entry in
            visited.append(entry.name)
            return true
        }

        XCTAssertTrue(visited.contains("._report.txt"))
        XCTAssertTrue(visited.contains("._nested.bin"))
        XCTAssertTrue(visited.contains(".DS_Store"))
        XCTAssertTrue(visited.contains("report.txt"))
    }

    func testScannerFindsMetadataAndProtectsFonts() {
        let plan = Scanner(scope: .adhoc).scan(root: root)

        let names = Set(plan.items.map(\.name))
        XCTAssertTrue(names.contains("._report.txt"))
        XCTAssertTrue(names.contains("._nested.bin"))
        XCTAssertTrue(names.contains(".DS_Store"))
        XCTAssertEqual(plan.protectedItems.count, 1)
        XCTAssertTrue(plan.protectedItems[0].hasSuffix("._Protected.ttf"))
        XCTAssertFalse(names.contains("report.txt"))
    }

    func testExecutorRemovesMatchesAndKeepsRealFiles() {
        let plan = Scanner(scope: .adhoc).scan(root: root)
        XCTAssertFalse(plan.isEmpty)

        let result = Executor.execute(plan, dryRun: false, log: nil)
        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")

        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("._report.txt").path))
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent(".DS_Store").path))
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("sub/._nested.bin").path))
        // Protected: kept.
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("._Protected.ttf").path))
        // Untouched: kept.
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("report.txt").path))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("sub/real.bin").path))
    }

    func testExecutorRefusesForbiddenRoot() {
        let plan = Scanner(scope: .adhoc).scan(root: URL(fileURLWithPath: "/usr/local"))
        let result = Executor.execute(plan, dryRun: false, log: nil)
        XCTAssertFalse(result.failures.isEmpty)
        XCTAssertEqual(result.removed, 0)
    }

    func testScannerDoesNotFollowSymlinksOutOfTree() throws {
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try write("x", to: "outside/.DS_Store")

        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let plan = Scanner(scope: .adhoc).scan(root: root)
        let throughLink = plan.items.filter { $0.path.hasPrefix(link.path) }
        XCTAssertTrue(throughLink.isEmpty, "walker must not descend through a symlink")
    }
}
