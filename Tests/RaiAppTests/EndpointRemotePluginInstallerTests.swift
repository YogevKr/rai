#if os(macOS)
import Foundation
import XCTest
import RaiCore
#if canImport(RaiApp)
@testable import RaiApp
#else
@testable import PluginHost
#endif

@MainActor
final class EndpointRemotePluginInstallerTests: XCTestCase {
    func testForegroundPreviewNeedsExactApprovalBeforeWriting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rai-plugin-pty-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("install.sh")
        let marker = root.appendingPathComponent("installed")
        try """
        printf 'Source: fixture/repo\\nResolved commit: fixture-commit\\nInstall this plugin? [y/N] '
        read answer
        if [ "$answer" = yes ]; then printf installed > "$1"; fi
        printf '\\nCommand finished\\n'
        """.write(to: script, atomically: true, encoding: .utf8)
        let previewReady = expectation(description: "preview")
        let finished = expectation(description: "finished")
        let prepare = EndpointPluginRequest(bootID: "boot", operation: .prepareInstall(source: "fixture/repo", reference: ""))
        var previewID: UUID?
        var finalResult: EndpointPluginResult?
        let installer = EndpointRemotePluginInstaller(request: prepare, isCurrent: { true }, deliver: { result in
            if result.requestID == prepare.id {
                previewID = result.value?.objectValue?["preview_id"]?.stringValue.flatMap(UUID.init(uuidString:))
                previewReady.fulfill()
            } else { finalResult = result; finished.fulfill() }
        })
        defer { installer.cancel() }
        try installer.start(binary: "/bin/sh", arguments: [script.path, marker.path])
        await fulfillment(of: [previewReady], timeout: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let id = try XCTUnwrap(previewID)
        let confirm = EndpointPluginRequest(bootID: "boot", operation: .confirmInstall(id))
        XCTAssertThrowsError(try installer.answer(confirm, previewID: UUID(), approve: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        try installer.answer(confirm, previewID: id, approve: true)
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertNil(finalResult?.error)
        XCTAssertEqual(try String(contentsOf: marker), "installed")
        XCTAssertThrowsError(try installer.answer(confirm, previewID: id, approve: true))
    }

    func testStaleMachineCannotApprovePreview() async throws {
        let previewReady = expectation(description: "preview")
        let prepare = EndpointPluginRequest(bootID: "boot", operation: .prepareInstall(source: "fixture/repo", reference: ""))
        var current = true
        var previewID: UUID?
        let installer = EndpointRemotePluginInstaller(request: prepare, isCurrent: { current }, deliver: { result in
            previewID = result.value?.objectValue?["preview_id"]?.stringValue.flatMap(UUID.init(uuidString:))
            previewReady.fulfill()
        })
        defer { installer.cancel() }
        try installer.start(binary: "/bin/sh", arguments: ["-c", "printf 'Install this plugin? [y/N] '; read answer"])
        await fulfillment(of: [previewReady], timeout: 5)
        current = false
        let id = try XCTUnwrap(previewID)
        XCTAssertThrowsError(try installer.answer(.init(bootID: "boot", operation: .confirmInstall(id)), previewID: id, approve: true))
    }

    func testOversizedPreviewCannotApprove() async throws {
        let stopped = expectation(description: "large preview rejected")
        var failure: String?
        let prepare = EndpointPluginRequest(bootID: "boot", operation: .prepareInstall(source: "fixture/repo", reference: ""))
        let installer = EndpointRemotePluginInstaller(request: prepare, isCurrent: { true }, deliver: { result in
            failure = result.error; stopped.fulfill()
        })
        defer { installer.cancel() }
        try installer.start(binary: "/bin/sh", arguments: ["-c", "dd if=/dev/zero bs=66000 count=1 2>/dev/null | tr '\\000' A; printf 'Install this plugin? [y/N] '; read answer"])
        await fulfillment(of: [stopped], timeout: 5)
        XCTAssertTrue(failure?.contains("64 KiB") == true)
    }

    func testUnexpectedApprovalStopsWithoutAnswering() async throws {
        let stopped = expectation(description: "unexpected prompt rejected")
        var failure: String?
        let prepare = EndpointPluginRequest(bootID: "boot", operation: .prepareInstall(source: "fixture/repo", reference: ""))
        let installer = EndpointRemotePluginInstaller(request: prepare, isCurrent: { true }, deliver: { result in
            failure = result.error; stopped.fulfill()
        })
        defer { installer.cancel() }
        try installer.start(binary: "/bin/sh", arguments: ["-c", "printf 'Trust this host? [y/N] '; read answer"])
        await fulfillment(of: [stopped], timeout: 5)
        XCTAssertTrue(failure?.contains("unexpected approval") == true)
    }
}
#endif
