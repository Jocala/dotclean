import XCTest
@testable import DotCleanCore

/// Catalog/adblink rule: any trimmed difference is "newer", including a
/// rollback. These tests lock that in so nobody "fixes" it into a numeric
/// compare and silently stops delivering a reverted release.
final class UpdatesTests: XCTestCase {
    func testEqualIsNotNewer() {
        XCTAssertFalse(Updates.isNewer("1.01", than: "1.01"))
    }

    func testTrailingNewlineAndSpacesAreNotNewer() {
        XCTAssertFalse(Updates.isNewer("1.01\n", than: "1.01"))
        XCTAssertFalse(Updates.isNewer("1.01\r\n", than: "1.01"))
        XCTAssertFalse(Updates.isNewer("  1.01  ", than: "1.01"))
        XCTAssertFalse(Updates.isNewer("1.01", than: "\n1.01\n"))
    }

    func testNewerVersion() {
        XCTAssertTrue(Updates.isNewer("1.02", than: "1.01"))
        XCTAssertTrue(Updates.isNewer("1.02\r\n", than: "1.01"))
    }

    func testRollbackStillCounts() {
        XCTAssertTrue(Updates.isNewer("1.0", than: "1.01"),
                      "a reverted release must still prompt")
    }

    func testEmptyReplyIsNeverNewer() {
        XCTAssertFalse(Updates.isNewer("", than: "1.01"))
        XCTAssertFalse(Updates.isNewer("   \n", than: "1.01"))
        XCTAssertFalse(Updates.isNewer("\n", than: "1"))
    }

    func testEndpoints() {
        XCTAssertEqual(Updates.versionURL.absoluteString,
                       "https://www.jocala.com/dotclean/version.txt")
        XCTAssertTrue(Updates.donateURL.absoluteString.hasPrefix("https://www.paypal.com/"))
        XCTAssertEqual(Updates.homeURL.absoluteString, "https://www.jocala.com/dotclean/")
    }
}
