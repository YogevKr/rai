import AppKit
import RaiCore
import SwiftUI
import XCTest
@testable import RaiApp

@MainActor
final class AppUpdateTests: XCTestCase {
    func testDevelopmentBuildNeverFetchesOrInstallsReleaseUpdates() async {
        let (defaults, name) = preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let model = AppUpdateController(
            currentVersion: "0.1.0", supportsUpdates: false, defaults: defaults,
            fetchRelease: { XCTFail("unexpected release fetch"); throw AppUpdateError.downloadFailed },
            installRelease: { _ in XCTFail("unexpected release install") },
            pruneCompletedUpdates: { XCTFail("unexpected release cleanup") }
        )
        model.start()
        defer { model.stop() }
        await model.check()
        XCTAssertFalse(model.isPresented)
        await model.check(manual: true)
        XCTAssertTrue(model.isPresented)
        guard case .failed(let message) = model.phase else {
            return XCTFail("expected development build explanation")
        }
        XCTAssertTrue(message.contains("Development builds"))
        await model.update()
        XCTAssertNil(model.release)
    }

    func testSkipSurvivesRestartAndDoesNotHideFutureVersions() async throws {
        let (defaults, name) = preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let release = try fixture(version: "0.1.49")
        let first = controller(defaults: defaults, release: release)
        await first.check()
        XCTAssertTrue(first.isPresented)
        XCTAssertEqual(first.phase, .available)
        first.skip()
        XCTAssertFalse(first.isPresented)

        let restarted = controller(defaults: defaults, release: release)
        await restarted.check()
        XCTAssertFalse(restarted.isPresented)
        await restarted.check(manual: true)
        XCTAssertTrue(restarted.isPresented)
        XCTAssertEqual(restarted.phase, .available)

        let future = controller(defaults: defaults, release: try fixture(version: "0.1.50"))
        await future.check()
        XCTAssertTrue(future.isPresented)
    }

    func testCurrentReleaseStaysQuietUntilAnExplicitCheck() async throws {
        let (defaults, name) = preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let model = controller(defaults: defaults, release: try fixture(version: "0.1.48"))
        await model.check()
        XCTAssertFalse(model.isPresented)
        await model.check(manual: true)
        XCTAssertTrue(model.isPresented)
        XCTAssertEqual(model.phase, .upToDate)
    }

    func testAutomaticNetworkFailureStaysQuietAndManualFailureIsVisible() async {
        let (defaults, name) = preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let model = AppUpdateController(
            currentVersion: "0.1.48", defaults: defaults,
            fetchRelease: { throw AppUpdateError.downloadFailed }, installRelease: { _ in XCTFail("unexpected install") }
        )
        await model.check()
        XCTAssertFalse(model.isPresented)
        await model.check(manual: true)
        XCTAssertTrue(model.isPresented)
        XCTAssertEqual(model.phase, .failed(AppUpdateError.downloadFailed.localizedDescription))
    }

    func testCheckingDoesNotInstallAndFailedInstallCanRetry() async throws {
        let (defaults, name) = preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let release = try fixture(version: "0.1.49")
        var attempts = 0
        let model = AppUpdateController(
            currentVersion: "0.1.48", defaults: defaults, fetchRelease: { release },
            installRelease: { received in
                XCTAssertEqual(received, release)
                attempts += 1
                throw AppUpdateError.invalidSignature
            }
        )
        await model.check()
        XCTAssertEqual(attempts, 0)
        await model.update()
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(model.phase, .failed(AppUpdateError.invalidSignature.localizedDescription))
        XCTAssertTrue(model.isPresented)
        await model.update()
        XCTAssertEqual(attempts, 2)
    }

    func testManualCheckDuringAutomaticFetchShowsSkippedReleaseOrError() async throws {
        for fail in [false, true] {
            let (defaults, name) = preferences()
            defer { defaults.removePersistentDomain(forName: name) }
            let release = try fixture(version: "0.1.49")
            defaults.set("0.1.49", forKey: AppUpdateController.skippedVersionKey)
            let started = expectation(description: "automatic request started")
            var finish: CheckedContinuation<AppRelease, Error>?
            var requests = 0
            let model = AppUpdateController(
                currentVersion: "0.1.48", defaults: defaults,
                fetchRelease: {
                    requests += 1
                    return try await withCheckedThrowingContinuation { finish = $0; started.fulfill() }
                }, installRelease: { _ in XCTFail("unexpected install") }
            )
            let automatic = Task { await model.check() }
            await fulfillment(of: [started], timeout: 2)
            await model.check(manual: true)
            XCTAssertTrue(model.isPresented)
            XCTAssertEqual(model.phase, .checking)
            if fail { finish?.resume(throwing: AppUpdateError.downloadFailed) }
            else { finish?.resume(returning: release) }
            await automatic.value
            XCTAssertEqual(requests, 1)
            XCTAssertEqual(model.phase, fail ? .failed(AppUpdateError.downloadFailed.localizedDescription) : .available)
        }
    }

    func testUpdatePanelConsumesBothSessionCloseShortcuts() throws {
        _ = NSApplication.shared
        let panel = AppUpdatePanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 290),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        var dismissals = 0
        panel.onDismiss = { dismissals += 1 }
        let shortcuts: [NSEvent.ModifierFlags] = [.command, [.command, .shift]]
        for flags in shortcuts {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: panel.windowNumber, context: nil,
                characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13
            ))
            XCTAssertTrue(panel.performKeyEquivalent(with: event))
        }
        XCTAssertEqual(dismissals, 2)
    }

    func testClosingDuringACheckDoesNotReopenTheDialog() async throws {
        let (defaults, name) = preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let release = try fixture(version: "0.1.49")
        let started = expectation(description: "request started")
        var finish: CheckedContinuation<AppRelease, Never>?
        let model = AppUpdateController(
            currentVersion: "0.1.48", defaults: defaults,
            fetchRelease: { await withCheckedContinuation { finish = $0; started.fulfill() } },
            installRelease: { _ in XCTFail("unexpected install") }
        )
        let check = Task { await model.check(manual: true) }
        await fulfillment(of: [started], timeout: 2)
        model.dismiss()
        finish?.resume(returning: release)
        await check.value
        XCTAssertFalse(model.isPresented)
    }

    func testInstallationBlocksDuplicateUpdatesAndSkip() async throws {
        let (defaults, name) = preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let release = try fixture(version: "0.1.49")
        let started = expectation(description: "installation started")
        var finish: CheckedContinuation<Void, Never>?
        var attempts = 0
        let model = AppUpdateController(
            currentVersion: "0.1.48", defaults: defaults, fetchRelease: { release },
            installRelease: { _ in
                attempts += 1
                await withCheckedContinuation { finish = $0; started.fulfill() }
            }
        )
        await model.check()
        let install = Task { await model.update() }
        await fulfillment(of: [started], timeout: 2)
        model.skip()
        model.dismiss()
        await model.update()
        await model.check(manual: true)
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(model.isPresented)
        XCTAssertNil(defaults.string(forKey: AppUpdateController.skippedVersionKey))
        finish?.resume()
        await install.value
    }

    func testUpdateDialogRendersWithAnOpaqueBackground() async throws {
        _ = NSApplication.shared
        let (defaults, name) = preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let model = controller(defaults: defaults, release: try fixture(version: "0.1.49"))
        await model.check()
        let renderer = ImageRenderer(content: AppUpdateDialog(model: model).environment(\.colorScheme, .dark))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        XCTAssertGreaterThan(bitmap.pixelsWide, 800)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 300)
        for point in [(2, 2), (bitmap.pixelsWide - 3, bitmap.pixelsHigh - 3)] {
            XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: point.0, y: point.1)).alphaComponent, 1, accuracy: 0.01)
        }
        if let output = ProcessInfo.processInfo.environment["RAI_UPDATE_DIALOG_SNAPSHOT"] {
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output))
        }
    }

    func testOfficialReleaseArchiveAndSignature() throws {
        guard let archivePath = ProcessInfo.processInfo.environment["RAI_UPDATE_ARCHIVE_PROBE"],
              let applicationPath = ProcessInfo.processInfo.environment["RAI_UPDATE_APP_PROBE"]
        else { throw XCTSkip("Set RAI_UPDATE_ARCHIVE_PROBE and RAI_UPDATE_APP_PROBE to verify the downloaded release.") }
        let archive = URL(fileURLWithPath: archivePath)
        let release = try fixture(
            version: "0.1.48", size: 7_307_811,
            sha256: "792b3f5807cad38a1cc0fa6c3c7c8c61136c630a280e1c92a5ea23621a9a96ce"
        )
        try AppUpdateService.verifyArchive(archive, release: release)
        try AppUpdateService.validateArchiveEntries(archive)
        try AppUpdateVerification.verifyApplication(at: URL(fileURLWithPath: applicationPath), version: "0.1.48")
        let wrongDigest = try fixture(version: "0.1.48", size: 7_307_811)
        XCTAssertThrowsError(try AppUpdateService.verifyArchive(archive, release: wrongDigest))
    }

    private func preferences() -> (UserDefaults, String) {
        let name = "rai-update-tests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func controller(defaults: UserDefaults, release: AppRelease) -> AppUpdateController {
        AppUpdateController(
            currentVersion: "0.1.48", defaults: defaults, fetchRelease: { release },
            installRelease: { _ in XCTFail("unexpected install") }
        )
    }

    private func fixture(version: String, size: Int64 = 1234, sha256: String = String(repeating: "a", count: 64)) throws -> AppRelease {
        let json: [String: Any] = [
            "tag_name": "v\(version)", "draft": false, "prerelease": false,
            "assets": [[
                "name": "Rai-\(version)-macos.zip", "state": "uploaded", "size": size,
                "browser_download_url": "https://github.com/YogevKr/rai/releases/download/v\(version)/Rai-\(version)-macos.zip",
                "digest": "sha256:\(sha256)",
            ]],
        ]
        return try XCTUnwrap(AppRelease.decode(JSONSerialization.data(withJSONObject: json)))
    }
}
