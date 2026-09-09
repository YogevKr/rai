import Foundation
import XCTest
@testable import RaiCore

final class MachineCatalogTests: XCTestCase {
    private let profile = "0123456789abcdef0123456789abcdef"

    func testEveryCatalogOperationUsesTheDocumentedCLI() throws {
        XCTAssertEqual(try MachineOperation.refresh.arguments(), ["machine", "list", "--json"])
        XCTAssertEqual(try MachineOperation.add(target: "dev@build", label: "Build Mac", session: "review").arguments(),
            ["machine", "add", "dev@build", "--label", "Build Mac", "--remote-session", "review"])
        XCTAssertEqual(try MachineOperation.rename(profileID: profile, label: "Other").arguments(), ["machine", "rename", profile, "--label", "Other"])
        XCTAssertEqual(try MachineOperation.remove(profileID: profile).arguments(), ["machine", "remove", profile])
        XCTAssertEqual(try MachineOperation.enable(profileID: profile).arguments(), ["machine", "enable", profile])
        XCTAssertEqual(try MachineOperation.disable(profileID: profile).arguments(), ["machine", "disable", profile])
    }

    func testRejectsOptionInjectionPasswordsAndInvalidSessions() {
        for target in ["", "-oProxyCommand=anything", "user:password@host", "ssh://user:password@host", "host name", "host\nother"] {
            XCTAssertThrowsError(try MachineOperation.add(target: target, label: "Machine", session: "default").arguments())
        }
        for session in ["", "..", "../default", "two sessions", String(repeating: "a", count: 65)] {
            XCTAssertThrowsError(try MachineOperation.add(target: "host", label: "Machine", session: session).arguments())
        }
        for id in ["-x", profile.uppercased(), "local", String(repeating: "f", count: 33)] {
            XCTAssertThrowsError(try MachineOperation.remove(profileID: id).arguments())
        }
    }

    func testLabelIsSingleArgumentAndCannotChangeTheTarget() throws {
        let label = "Build; $(echo hidden) `echo hidden` --remote-session wrong"
        let arguments = try MachineOperation.rename(profileID: profile, label: label).arguments()
        XCTAssertEqual(arguments.count, 5)
        XCTAssertEqual(arguments.last, label)
        XCTAssertThrowsError(try MachineOperation.rename(profileID: profile, label: "\n").arguments())
        XCTAssertThrowsError(try MachineOperation.rename(profileID: profile, label: String(repeating: "é", count: 65)).arguments())
    }

    func testCatalogPreservesOpaqueIdentityAndRejectsDuplicates() throws {
        let row: [String: Any] = ["id": profile, "label": "Machine", "target": "dev@host", "session": "review", "enabled": false, "selected": false]
        let machines = try MachineCatalog.parse(JSONSerialization.data(withJSONObject: [row]))
        XCTAssertEqual(machines.first?.endpoint, MachineEndpoint(profileID: profile, session: "review"))
        XCTAssertEqual(machines.first?.enabled, false)
        XCTAssertThrowsError(try MachineCatalog.parse(JSONSerialization.data(withJSONObject: [row, row])))
        XCTAssertThrowsError(try MachineCatalog.parse(Data(repeating: 32, count: 131_073)))
    }

    func testResourceKeysSeparateMachinesSessionsConnectionsAndServerBoots() {
        let local = MachineEndpoint(session: "default")
        let remote = MachineEndpoint(profileID: profile, session: "default")
        let named = MachineEndpoint(profileID: profile, session: "other")
        let references = [local, remote, named].map { MachineResource(endpoint: $0, connectionID: "connection", bootID: "boot", paneID: "w1:p1") }
            + [MachineResource(endpoint: remote, connectionID: "next", bootID: "boot", paneID: "w1:p1"),
               MachineResource(endpoint: remote, connectionID: "connection", bootID: "next", paneID: "w1:p1")]
        XCTAssertEqual(Set(references).count, 5)
    }

    func testBridgeIdentityAndMachineMessagesRoundTrip() throws {
        let endpoint = MachineEndpoint(profileID: profile, session: "review")
        let identity = EndpointViewIdentity(connectionID: "generation", machineEndpoint: endpoint)
        XCTAssertEqual(try JSONDecoder().decode(EndpointViewIdentity.self, from: JSONEncoder().encode(identity)), identity)
        let legacy = Data("{\"connectionID\":\"legacy\",\"viewID\":\"\(UUID().uuidString)\"}".utf8)
        XCTAssertNil(try JSONDecoder().decode(EndpointViewIdentity.self, from: legacy).machineEndpoint)
        let state = MachineDirectoryState(entries: [.init(endpoint: endpoint, label: "Review")])
        let messages: [BridgeMessage] = [.machineState(state), .machineRequest(.init(revision: state.revision, operation: .disable(profileID: profile)))]
        for message in messages {
            let encoded = try JSONEncoder().encode(message)
            let decoded = try JSONDecoder().decode(BridgeMessage.self, from: encoded)
            let left = try JSONSerialization.jsonObject(with: encoded) as? NSDictionary
            let right = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? NSDictionary
            XCTAssertEqual(left, right)
        }
    }
}
