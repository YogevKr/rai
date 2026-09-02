import XCTest

@testable import RaiApp

final class APNsPayloadBuilderTests: XCTestCase {
    func testAlertPayloadGroupsByWorkspaceAndCarriesStableIdentifier() throws {
        let data = try APNsPayloadBuilder.alert(
            title: "Build",
            subtitle: "rai",
            body: "Needs you",
            paneID: "pane-1",
            workspaceID: "workspace-1",
            workspace: "rai",
            category: "agent-attention",
            notificationIDs: ["agent-pane-1"],
            threadID: "workspace-1",
            summaryArgument: "rai",
            summaryArgumentCount: 1,
            occurredAt: Date(timeIntervalSince1970: 100),
            badge: 2
        )
        let root = try json(data)
        let aps = try XCTUnwrap(root["aps"] as? [String: Any])
        let alert = try XCTUnwrap(aps["alert"] as? [String: Any])

        XCTAssertEqual(aps["thread-id"] as? String, "workspace-1")
        XCTAssertEqual(alert["summary-arg"] as? String, "rai")
        XCTAssertEqual(alert["summary-arg-count"] as? Int, 1)
        XCTAssertEqual(root["notificationID"] as? String, "agent-pane-1")
        XCTAssertEqual(root["notificationIDs"] as? [String], ["agent-pane-1"])
        XCTAssertEqual(root["notificationTimestamp"] as? Double, 100)
        XCTAssertEqual(root["paneID"] as? String, "pane-1")
        XCTAssertEqual(aps["category"] as? String, "agent-attention")
    }

    func testBurstPayloadHasNoPaneLinkOrActions() throws {
        let data = try APNsPayloadBuilder.alert(
            title: "2 agents need you",
            subtitle: "rai",
            body: "Build, Tests",
            paneID: nil,
            workspaceID: "workspace-1",
            workspace: "rai",
            category: nil,
            notificationIDs: ["agent-pane-1", "agent-pane-2"],
            threadID: "workspace-1",
            summaryArgument: "rai",
            summaryArgumentCount: 2,
            occurredAt: Date(timeIntervalSince1970: 100),
            badge: 1
        )
        let root = try json(data)
        let aps = try XCTUnwrap(root["aps"] as? [String: Any])
        let alert = try XCTUnwrap(aps["alert"] as? [String: Any])

        XCTAssertNil(root["paneID"])
        XCTAssertNil(aps["category"])
        XCTAssertEqual(root["triage"] as? Bool, true)
        XCTAssertEqual(alert["summary-arg-count"] as? Int, 2)
    }

    func testRetractionPayloadIsSilentBackgroundContent() throws {
        let data = try APNsPayloadBuilder.retraction(
            notificationIDs: ["agent-pane-1", "agent-pane-2"],
            retractedBefore: Date(timeIntervalSince1970: 200)
        )
        let root = try json(data)
        let aps = try XCTUnwrap(root["aps"] as? [String: Any])

        XCTAssertEqual(aps as NSDictionary, ["content-available": 1] as NSDictionary)
        XCTAssertEqual(
            root["retractNotificationIDs"] as? [String],
            ["agent-pane-1", "agent-pane-2"]
        )
        XCTAssertEqual(root["retractedBefore"] as? Double, 200)
    }

    func testAlertPayloadTrimsDisplayBodyToAPNsLimit() throws {
        let data = try APNsPayloadBuilder.alert(
            title: "Burst",
            subtitle: "rai",
            body: String(repeating: "agent-name, ", count: 1_000),
            paneID: nil,
            workspaceID: "workspace-1",
            workspace: "rai",
            category: nil,
            notificationIDs: ["agent-pane-1", "agent-pane-2"],
            threadID: "workspace-1",
            summaryArgument: "rai",
            summaryArgumentCount: 2,
            occurredAt: Date(timeIntervalSince1970: 100),
            badge: 1
        )

        XCTAssertLessThanOrEqual(data.count, APNsPayloadBuilder.maximumPayloadBytes)
        let root = try json(data)
        let aps = try XCTUnwrap(root["aps"] as? [String: Any])
        let alert = try XCTUnwrap(aps["alert"] as? [String: Any])
        XCTAssertTrue(try XCTUnwrap(alert["body"] as? String).hasSuffix("…"))
    }

    func testRetractionPayloadSplitsWithoutDroppingIdentifiers() throws {
        let identifiers = (0..<300).map {
            "agent-\($0)-" + String(repeating: "x", count: 40)
        }
        let batches = try APNsPayloadBuilder.retractionBatches(
            notificationIDs: identifiers,
            retractedBefore: Date(timeIntervalSince1970: 200)
        )

        XCTAssertGreaterThan(batches.count, 1)
        XCTAssertTrue(batches.allSatisfy {
            $0.count <= APNsPayloadBuilder.maximumPayloadBytes
        })
        let decoded = try batches.flatMap { data in
            try XCTUnwrap(json(data)["retractNotificationIDs"] as? [String])
        }
        XCTAssertEqual(decoded, identifiers)
    }

    func testRetractionBatchRequestsIdentifyEachPayloadsIdentifiers() throws {
        let identifiers = (0..<300).map {
            "agent-\($0)-" + String(repeating: "x", count: 40)
        }
        let batches = try APNsPayloadBuilder.retractionBatchRequests(
            notificationIDs: identifiers,
            retractedBefore: Date(timeIntervalSince1970: 200)
        )

        XCTAssertGreaterThan(batches.count, 1)
        XCTAssertEqual(batches.flatMap(\.notificationIDs), identifiers)
        for batch in batches {
            XCTAssertEqual(
                try json(batch.payload)["retractNotificationIDs"] as? [String],
                batch.notificationIDs
            )
        }
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
