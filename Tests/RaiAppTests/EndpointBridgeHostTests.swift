import Foundation
import RaiCore
import XCTest
@testable import RaiApp

@MainActor
final class EndpointBridgeHostTests: XCTestCase {
    func testWrongViewAndOutOfOrderRequestsNeverOpenAnEndpoint() async throws {
        let identity = EndpointViewIdentity(connectionID: "lab")
        for request in [
            EndpointBridgeRequest(identity: EndpointViewIdentity(connectionID: "lab"), sequence: 1, operation: .open(columns: 80, rows: 24)),
            EndpointBridgeRequest(identity: identity, sequence: 2, operation: .open(columns: 80, rows: 24)),
            EndpointBridgeRequest(identity: identity, sequence: 1, bootID: "old", operation: .open(columns: 80, rows: 24)),
        ] {
            let emitted = expectation(description: "identity rejection")
            let host = EndpointBridgeHost(identity: identity, socketPath: "/nonexistent/lab.sock") { state, done in
                XCTAssertEqual(state.identity, identity)
                XCTAssertEqual(state.error, HerdrEndpointError.staleIdentity.localizedDescription)
                XCTAssertNil(state.snapshot)
                emitted.fulfill()
                done()
            }
            host.handle(request)
            await fulfillment(of: [emitted], timeout: 1)
            host.stop()
        }
    }

    func testRetainedRemoteOwnershipRejectsForeignViewsAndEndsWhenStopped() async {
        let identity = EndpointViewIdentity(connectionID: "captured-main")
        let remote = RemoteConnection.Context(target: "user@fixture", sessionName: "review", remoteSocketPath: "/fixture/herdr.sock")
        let host = EndpointBridgeHost(identity: identity, socketPath: "/old-forward.sock", remoteContext: remote) { _, done in done() }
        let local = EndpointBridgeHost(identity: identity, socketPath: "/local.sock") { _, done in done() }
        XCTAssertTrue(host.ownsRetainedConnection(identity))
        XCTAssertFalse(local.ownsRetainedConnection(identity))
        XCTAssertFalse(host.ownsRetainedConnection(.init(connectionID: identity.connectionID)))
        XCTAssertFalse(host.ownsRetainedConnection(.init(connectionID: "replacement", viewID: identity.viewID)))
        host.handle(.init(identity: .init(connectionID: identity.connectionID), sequence: 1, operation: .open(columns: 80, rows: 24)))
        XCTAssertFalse(host.ownsRetainedConnection(identity), "A foreign request invalidates its host instead of gaining retained ownership.")
        host.stop(); local.stop()
        XCTAssertFalse(host.ownsRetainedConnection(identity))
    }

    func testInvalidSizeStopsBeforeSocketConnection() async {
        let identity = EndpointViewIdentity(connectionID: "lab")
        let emitted = expectation(description: "size rejection")
        let host = EndpointBridgeHost(identity: identity, socketPath: "/nonexistent/lab.sock") { state, done in
            XCTAssertEqual(state.error, HerdrEndpointError.limitExceeded.localizedDescription)
            emitted.fulfill()
            done()
        }
        host.handle(EndpointBridgeRequest(identity: identity, sequence: 1, operation: .open(columns: 241, rows: 24)))
        await fulfillment(of: [emitted], timeout: 1)
        host.stop()
    }

    func testForeignMachineCannotUseDuplicatePaneForInputClosureHistoryOrPopupDecision() async throws {
        let machine = MachineEndpoint(profileID: String(repeating: "a", count: 32), session: "default")
        let identity = EndpointViewIdentity(connectionID: "same-connection", machineEndpoint: machine)
        let foreign = EndpointViewIdentity(connectionID: identity.connectionID, viewID: identity.viewID,
            machineEndpoint: .init(profileID: String(repeating: "b", count: 32), session: "default"))
        let operations: [EndpointBridgeOperation] = [
            .open(columns: 80, rows: 24),
            .input(paneID: "w1:p1", input: .text("must not send")),
            .command(.closePane("w1:p1")), .close,
            .terminalAction(.init(bootID: "boot", paneID: "w1:p1",
                action: .history(startRow: 0, endRow: 0, endColumn: 0, revision: 1, truncated: false))),
            .popupInput(terminalID: "w1:p1", input: .text("y")),
        ]
        for operation in operations {
            let rejected = expectation(description: "foreign machine rejected")
            let host = EndpointBridgeHost(identity: identity, socketPath: "/nonexistent/duplicate-pane.sock") { state, done in
                XCTAssertEqual(state.error, HerdrEndpointError.staleIdentity.localizedDescription)
                XCTAssertNil(state.snapshot)
                XCTAssertNil(state.terminalResult)
                rejected.fulfill(); done()
            }
            let bootID: String? = operation == .open(columns: 80, rows: 24) ? nil : "boot"
            host.handle(.init(identity: foreign, sequence: 1, bootID: bootID, projectionRevision: 1, operation: operation))
            await fulfillment(of: [rejected], timeout: 1)
            host.stop()
        }
    }

    func testAuditRecordsInputLengthWithoutTerminalText() throws {
        let request = EndpointBridgeRequest(identity: EndpointViewIdentity(connectionID: "lab"), sequence: 1,
            operation: .input(paneID: "w1:p1", input: .paste("private terminal text")))
        let audit = try XCTUnwrap(BridgeAuditEvent( .endpointRequest(request)))
        XCTAssertEqual(audit.action, "endpoint.input")
        XCTAssertEqual(audit.targetIDs["pane_id"], "w1:p1")
        XCTAssertEqual(audit.content, .bytes(37)) // Input budget includes a 16-byte framing allowance.
        XCTAssertNil(BridgeAuditEvent( .endpointState(EndpointBridgeState(identity: request.identity,
            sequence: 1, snapshot: nil, surface: nil, methods: [], busy: false, error: nil))))
    }
}
