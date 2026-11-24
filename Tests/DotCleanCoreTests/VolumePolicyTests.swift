import XCTest
@testable import DotCleanCore

/// `fstype` is a transport, not an origin: an SMB share can front a Mac's APFS
/// disk (m1's `kath`), where deleting `._`/`.DS_Store` is exactly what the tool
/// exists to avoid. These tests lock the host-based opt-in down.
final class VolumePolicyTests: XCTestCase {
    func testSMBHostParsing() {
        XCTAssertEqual(Volume.host(from: "//jeff@192.168.1.39/storage"), "192.168.1.39")
        XCTAssertEqual(Volume.host(from: "//kath@m1._smb._tcp.local/kath"), "m1._smb._tcp.local")
        XCTAssertEqual(Volume.host(from: "//jeff@192.168.20.10/torrents"), "192.168.20.10")
        XCTAssertEqual(Volume.host(from: "//HOST/share"), "host", "hosts compare case-insensitively")
    }

    func testNFSHostParsing() {
        XCTAssertEqual(Volume.host(from: "192.168.1.39:/export/tv"), "192.168.1.39")
    }

    func testLocalDeviceHasNoHost() {
        XCTAssertNil(Volume.host(from: "/dev/disk4s1"))
        XCTAssertNil(Volume.host(from: ""))
    }

    func testLocalNonMacIsAutomatic() {
        let stick = Volume(mountPoint: "/Volumes/stick", fsType: "exfat",
                           source: "/dev/disk4s1", isLocal: true,
                           isRemovable: true, isInternal: false)
        XCTAssertTrue(stick.allowsAutomaticClean(allowedHosts: []))
    }

    func testNetworkShareNeedsAnAllowedHost() {
        let debian = Volume(mountPoint: "/Volumes/storage", fsType: "smbfs",
                            source: "//jeff@192.168.1.39/storage", isLocal: false,
                            isRemovable: false, isInternal: false)
        XCTAssertFalse(debian.allowsAutomaticClean(allowedHosts: []),
                       "network shares are manual until their host is named")
        XCTAssertTrue(debian.allowsAutomaticClean(allowedHosts: ["192.168.1.39"]))
        XCTAssertFalse(debian.allowsAutomaticClean(allowedHosts: ["192.168.20.10"]))
    }

    func testMacShareStaysUntouchableEvenIfHostAllowed() {
        let macAPFS = Volume(mountPoint: "/Volumes/data", fsType: "apfs",
                             source: "/dev/disk5s1", isLocal: true,
                             isRemovable: false, isInternal: true)
        XCTAssertFalse(macAPFS.allowsAutomaticClean(allowedHosts: ["anything"]))

        let smbToMac = Volume(mountPoint: "/Volumes/kath", fsType: "smbfs",
                              source: "//kath@m1._smb._tcp.local/kath", isLocal: false,
                              isRemovable: false, isInternal: false)
        XCTAssertFalse(smbToMac.allowsAutomaticClean(allowedHosts: []))
    }

    func testNetworkVolumeWithoutSourceStaysManual() {
        let unknown = Volume(mountPoint: "/Volumes/x", fsType: "smbfs",
                             isLocal: false, isRemovable: false, isInternal: false)
        XCTAssertFalse(unknown.allowsAutomaticClean(allowedHosts: ["192.168.1.39"]))
    }

    func testNonMacStillCleanableOnRequest() {
        let debian = Volume(mountPoint: "/Volumes/storage", fsType: "smbfs",
                            source: "//jeff@192.168.1.39/storage", isLocal: false,
                            isRemovable: false, isInternal: false)
        XCTAssertTrue(debian.isTarget)
        XCTAssertFalse(debian.isMacFormat)
    }
}
