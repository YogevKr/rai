import XCTest
@testable import RaiCore

final class AppReleaseTests: XCTestCase {
    func testVersionsUseNumericOrderAndRejectNonReleaseVersions() throws {
        XCTAssertLessThan(try XCTUnwrap(AppReleaseVersion("0.1.9")), try XCTUnwrap(AppReleaseVersion("v0.1.48")))
        XCTAssertLessThan(try XCTUnwrap(AppReleaseVersion("0.9.99")), try XCTUnwrap(AppReleaseVersion("1.0.0")))
        for invalid in ["", "1.2", "1.2.3.4", "1.2.-1", "1.2.3-beta", "1.2.3+build", " 1.2.3", "１.2.3"] {
            XCTAssertNil(AppReleaseVersion(invalid), invalid)
        }
    }

    func testDecodeAcceptsOnlyTheOfficialStableArchive() throws {
        let release = try XCTUnwrap(AppRelease.decode(fixture()))
        XCTAssertEqual(release.version.description, "0.1.49")
        XCTAssertEqual(release.size, 1234)
        XCTAssertNil(try AppRelease.decode(fixture(release: ["prerelease": true])))
        XCTAssertNil(try AppRelease.decode(fixture(release: ["draft": true])))
        XCTAssertNil(try AppRelease.decode(fixture(release: ["tag_name": "v0.1.49-beta"])))
        XCTAssertNil(try AppRelease.decode(fixture(asset: ["name": "source.zip"])))
        XCTAssertNil(try AppRelease.decode(fixture(asset: ["state": "new"])))
        XCTAssertNil(try AppRelease.decode(fixture(asset: ["browser_download_url": "https://example.com/Rai.zip"])))
        XCTAssertNil(try AppRelease.decode(fixture(asset: ["browser_download_url": "http://github.com/YogevKr/rai/releases/download/v0.1.49/Rai-0.1.49-macos.zip"])))
    }

    func testDecodeRequiresACompleteDigestAndBoundedSize() throws {
        let digests: [Any] = [NSNull(), "sha256:abc", "md5:" + String(repeating: "a", count: 64),
                              "sha256:" + String(repeating: "g", count: 64)]
        for digest in digests {
            XCTAssertNil(try AppRelease.decode(fixture(asset: ["digest": digest])))
        }
        for size in [Int64(0), -1, AppRelease.maximumArchiveBytes + 1] {
            XCTAssertNil(try AppRelease.decode(fixture(asset: ["size": size])))
        }
    }

    func testOfferRequiresANewerVersionAndSkipOnlyAffectsAutomaticChecks() throws {
        let release = try XCTUnwrap(AppRelease.decode(fixture()))
        XCTAssertTrue(release.shouldOffer(currentVersion: "0.1.48", skippedVersion: nil, manual: false))
        XCTAssertFalse(release.shouldOffer(currentVersion: "0.1.49", skippedVersion: nil, manual: true))
        XCTAssertFalse(release.shouldOffer(currentVersion: "0.1.50", skippedVersion: nil, manual: true))
        XCTAssertFalse(release.shouldOffer(currentVersion: "dev", skippedVersion: nil, manual: true))
        XCTAssertFalse(release.shouldOffer(currentVersion: "0.1.48", skippedVersion: "0.1.49", manual: false))
        XCTAssertTrue(release.shouldOffer(currentVersion: "0.1.48", skippedVersion: "0.1.49", manual: true))
        XCTAssertTrue(release.shouldOffer(currentVersion: "0.1.48", skippedVersion: "0.1.47", manual: false))
    }

    private func fixture(release changes: [String: Any] = [:], asset assetChanges: [String: Any] = [:]) throws -> Data {
        var asset: [String: Any] = [
            "name": "Rai-0.1.49-macos.zip", "state": "uploaded", "size": 1234,
            "browser_download_url": "https://github.com/YogevKr/rai/releases/download/v0.1.49/Rai-0.1.49-macos.zip",
            "digest": "sha256:" + String(repeating: "a", count: 64),
        ]
        asset.merge(assetChanges) { _, new in new }
        var release: [String: Any] = ["tag_name": "v0.1.49", "draft": false, "prerelease": false, "assets": [asset]]
        release.merge(changes) { _, new in new }
        return try JSONSerialization.data(withJSONObject: release)
    }
}
