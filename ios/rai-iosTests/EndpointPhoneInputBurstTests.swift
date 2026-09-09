import Foundation
import RaiCore
import XCTest
#if os(iOS)
@testable import rai
#endif

@MainActor
final class EndpointPhoneInputBurstTests: XCTestCase {
    func testFastCommittedTextDeliversEveryCharacterInOrder() async throws {
        let model = EndpointPhoneModel()
        defer { model.disconnect() }
        var requests: [EndpointBridgeRequest] = []
        model.open(connectionID: "burst-fixture") { requests.append($0) }
        try receiveReadyState(model)
        XCTAssertTrue(model.acceptsInput)
        let text = String(repeating: "aßג", count: 200)
        for character in text { model.input(.text(String(character))) }
        XCTAssertNil(model.error, "A keyboard burst must not discard pending input")
        for _ in 0..<100 { await Task.yield() }
        let received = requests.reduce(into: "") { text, request in
            if case .input("phone", .text(let value)) = request.operation { text += value }
        }
        XCTAssertEqual(received, text)
        XCTAssertNil(model.error)
        XCTAssertEqual(requests.map(\.sequence), requests.indices.map { UInt64($0 + 1) })
    }
    func testTextNeverMergesAcrossKeysOrPaste() async throws {
        let model = EndpointPhoneModel()
        defer { model.disconnect() }
        var requests: [EndpointBridgeRequest] = []
        model.open(connectionID: "burst-order") { requests.append($0) }
        try receiveReadyState(model)
        let prefix = String(repeating: "a", count: 200)
        let suffix = String(repeating: "ב", count: 200)
        for character in prefix { model.input(.text(String(character))) }
        model.input(.special(.enter, modifiers: 0))
        model.input(.paste("literal\npaste"))
        for character in suffix { model.input(.text(String(character))) }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertNil(model.error)
        XCTAssertEqual(requests.map(\.operation), [
            .open(columns: 80, rows: 32), .input(paneID: "phone", input: .text(prefix)),
            .input(paneID: "phone", input: .special(.enter, modifiers: 0)),
            .input(paneID: "phone", input: .paste("literal\npaste")),
            .input(paneID: "phone", input: .text(suffix)),
        ])
        XCTAssertEqual(requests.map(\.sequence), [1, 2, 3, 4, 5])
    }

    private func receiveReadyState(_ model: EndpointPhoneModel) throws {
        let snapshot = try JSONDecoder().decode(HerdrEndpointSnapshot.self,
            from: Data(#"{"boot_id":"boot","revision":1,"focused_pane_id":"phone"}"#.utf8))
        let surface = try EndpointPhoneTestSurface.make(paneID: "phone")
        model.receive(.init(identity: try XCTUnwrap(model.identity), sequence: 1,
            snapshot: snapshot, surface: surface, methods: [], busy: false, error: nil))
    }

}
