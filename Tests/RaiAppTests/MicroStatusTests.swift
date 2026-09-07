import Combine
import IOKit
import RaiCore
import XCTest
@testable import RaiApp

@MainActor
final class MicroStatusTests: XCTestCase {
    func testPermissionFailureCanRetryWithoutLosingBindingsOrEnabledPreference() throws {
        let name = "MicroStatusTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let status = MicroStatusCenter(defaults: defaults)
        status.isEnabled = true
        status.bindings[.dialPress] = .sendReturn
        status.recordTransportError(.ioReturn(kIOReturnNotPermitted))
        XCTAssertFalse(status.isConnected)
        XCTAssertTrue(status.needsInputMonitoring)
        XCTAssertTrue(try XCTUnwrap(status.lastError).contains("Input Monitoring"))

        var retries = 0
        let observer = status.retryRequests.sink { retries += 1 }
        defer { observer.cancel() }
        status.retryConnection()
        XCTAssertEqual(retries, 1)
        XCTAssertNil(status.lastError)
        XCTAssertFalse(status.needsInputMonitoring)
        XCTAssertTrue(status.isEnabled)
        let restarted = MicroStatusCenter(defaults: defaults)
        XCTAssertTrue(restarted.isEnabled)
        XCTAssertEqual(restarted.bindings[.dialPress], .sendReturn)

        status.isEnabled = false
        status.retryConnection()
        XCTAssertEqual(retries, 1)
    }

    func testSuccessfulAttachClearsPermissionFailureAndSeizedDeviceHasDifferentRecovery() throws {
        let name = "MicroStatusTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let status = MicroStatusCenter(defaults: defaults)
        status.recordTransportError(.ioReturn(kIOReturnNotPermitted))
        status.deviceAttached(identity: nil)
        XCTAssertTrue(status.isConnected)
        XCTAssertNil(status.lastError)
        XCTAssertFalse(status.needsInputMonitoring)
        status.deviceDetached()
        status.recordTransportError(.ioReturn(kIOReturnExclusiveAccess))
        XCTAssertFalse(status.needsInputMonitoring)
        XCTAssertTrue(try XCTUnwrap(status.lastError).contains("Karabiner"))
    }
}
