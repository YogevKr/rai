import XCTest
@testable import RaiCore

final class CodexMicroTests: XCTestCase {
    private func identity(
        id: UInt64,
        pairs: [MicroUsagePair],
        input: Int = 64,
        output: Int = 64,
        transport: MicroTransportKind = .bluetooth,
        product: String = "Codex Micro #1"
    ) -> MicroDeviceIdentity {
        MicroDeviceIdentity(
            vendorID: IOHIDMicroTransport.vendorID,
            productID: IOHIDMicroTransport.productIDs[0],
            usagePage: 1,
            usagePairs: pairs,
            manufacturer: "Work Louder",
            product: product,
            transport: transport,
            maxInputReportSize: input,
            maxOutputReportSize: output,
            registryEntryID: id
        )
    }

    /// Encode models HOST->DEVICE, decode models DEVICE->HOST, and the vendor
    /// protocol is asymmetric: outgoing JSON-RPC carries no terminator
    /// (`_sendJsonRpcRequest` -> `sendData(request)` verbatim), while incoming
    /// traffic is newline-delimited (`buffers[channel].split(/\r?\n/)`). So the
    /// two directions cannot round-trip; device traffic is framed with this.
    private func deviceFrames(
        _ payload: String,
        channel: MicroChannel = .jsonRPC
    ) throws -> [[UInt8]] {
        try MicroFraming.encode(payload + "\n", channel: channel)
    }

    func testEncodeMatchesVendorChunking() throws {
        let payload = #"{"method":"v.oai.test","params":{"text":""#
            + String(repeating: "é", count: 90)
            + #""},"id":12}"#
        let reports = try MicroFraming.encode(payload)
        XCTAssertGreaterThanOrEqual(reports.count, 4)
        XCTAssertTrue(reports.allSatisfy {
            $0.count == 64 && $0[0] == 0x06 && $0[1] == 2 && $0[2] <= 61
        })
        // Every report except the last is a full 61-byte chunk.
        XCTAssertTrue(reports.dropLast().allSatisfy { $0[2] == 61 })
    }

    func testExactMultipleEmitsNoTerminatorReport() throws {
        let payload = #"{"x":""# + String(repeating: "a", count: 53) + #""}"#
        XCTAssertEqual(payload.utf8.count, 61)
        // The vendor sender loops `while (offset < length)` — an exact multiple
        // of 61 produces one report, never a trailing empty one.
        XCTAssertEqual(try MicroFraming.encode(payload).map { $0[2] }, [61])
    }

    func testDecodeReassemblesNewlineDelimitedMessage() throws {
        let payload = #"{"m":"v.oai.test","p":""#
            + String(repeating: "x", count: 100) + #""}"#
        let reports = try deviceFrames(payload)
        var decoder = MicroFrameDecoder()
        XCTAssertEqual(decoder.consume(reports[0]), [])
        XCTAssertEqual(
            reports.dropFirst().flatMap { decoder.consume($0) },
            [.payload(payload)]
        )
    }

    func testFullSizeFragmentCanCompleteAMessage() throws {
        // A 61-byte fragment ending in a newline terminates a message. The old
        // length-based rule treated full fragments as continuations and would
        // have stalled here forever.
        let payload = #"{"m":"v.oai.hid","p":{"k":"AG03","act":1}}"#
        var decoder = MicroFrameDecoder()
        let reports = try deviceFrames(payload)
        XCTAssertEqual(reports.flatMap { decoder.consume($0) }, [.payload(payload)])
    }

    func testSingleReportCarryingTwoMessagesEmitsBoth() throws {
        let a = #"{"m":"v.oai.hid","p":{"k":"AG00","act":1}}"#
        let b = #"{"m":"v.oai.hid","p":{"k":"AG00","act":0}}"#
        var decoder = MicroFrameDecoder()
        let outputs = try deviceFrames(a + "\n" + b).flatMap { decoder.consume($0) }
        XCTAssertEqual(outputs, [.payload(a), .payload(b)])
    }

    func testFragmentResynchronizesDroppedMessage() throws {
        let dropped = try deviceFrames(
            #"{"m":"v.oai.old","p":""# + String(repeating: "x", count: 80) + #""}"#
        )
        let replacement = #"{"m":"v.oai.hid","p":{"k":"AG00","act":1}}"#
        var decoder = MicroFrameDecoder()
        XCTAssertEqual(decoder.consume(dropped[0]), [])
        XCTAssertEqual(
            try deviceFrames(replacement).flatMap { decoder.consume($0) },
            [.payload(replacement)]
        )
    }

    func testBufferBoundResetsAccumulator() throws {
        var decoder = MicroFrameDecoder(maximumBufferSize: 70)
        let long = try deviceFrames(
            #"{"m":"v.oai.test","p":""# + String(repeating: "x", count: 100) + #""}"#
        )
        XCTAssertEqual(decoder.consume(long[0]), [])
        XCTAssertEqual(decoder.consume(long[1]), [])
        let valid = #"{"m":"v.oai.hid","p":{"k":"AG01","act":0}}"#
        XCTAssertEqual(
            try deviceFrames(valid).flatMap { decoder.consume($0) },
            [.payload(valid)]
        )
    }

    func testDebugLogUsesSeparatePath() throws {
        var decoder = MicroFrameDecoder()
        XCTAssertEqual(
            try deviceFrames("boot ok", channel: .debugLog)
                .flatMap { decoder.consume($0) },
            [.debugLog("boot ok")]
        )
    }

    func testCarriageReturnLineEndingsAreAccepted() throws {
        // The vendor splits on /\r?\n/.
        let payload = #"{"m":"v.oai.hid","p":{"k":"AG02","act":1}}"#
        var decoder = MicroFrameDecoder()
        XCTAssertEqual(
            try MicroFraming.encode(payload + "\r\n").flatMap { decoder.consume($0) },
            [.payload(payload)]
        )
    }

    func testRPCDecodesHIDEventsAndUnknownKey() {
        XCTAssertEqual(
            MicroRPCDecoder.decodePayload(
                #"{"method":"v.oai.hid","params":{"k":"AG05","act":1,"ag":5}}"#
            ),
            .agentKey(index: 5, state: .press)
        )
        XCTAssertEqual(
            MicroRPCDecoder.decodePayload(
                #"{"method":"v.oai.hid","params":{"k":"ACT12","act":0}}"#
            ),
            .commandKey(id: "ACT12", state: .release)
        )
        XCTAssertEqual(
            MicroRPCDecoder.decodePayload(
                #"{"method":"v.oai.hid","params":{"k":"ENC_CW","act":2}}"#
            ),
            .encoder(.clockwise)
        )
        guard case .unknown(let method, _) = MicroRPCDecoder.decodePayload(
            #"{"method":"v.oai.hid","params":{"k":"NOPE","act":1}}"#
        ) else {
            return XCTFail("unknown key should remain observable")
        }
        XCTAssertEqual(method, "v.oai.hid")
    }

    func testRPCDecodesJoystickAsSampleNotEdge() {
        // Decoding stays raw: the stick is analog, so press/release is a
        // property of the sample STREAM, not of any single sample.
        XCTAssertEqual(
            MicroRPCDecoder.decodePayload(
                #"{"method":"v.oai.rad","params":{"a":0.25,"d":1.0}}"#
            ),
            .joystickSample(angle: 0.25, distance: 1.0)
        )
        XCTAssertEqual(
            MicroRPCDecoder.decodePayload(
                #"{"method":"v.oai.rad","params":{"a":0.75,"d":0.0}}"#
            ),
            .joystickSample(angle: 0.75, distance: 0.0)
        )
    }

    func testRequestIDsWrapAt999() throws {
        var encoder = MicroRPCEncoder(startingAt: 999)
        let first = try encoder.request(method: "device.status", params: [String: String]())
        let second = try encoder.request(method: "device.status", params: [String: String]())
        XCTAssertEqual(first.id, 999)
        XCTAssertEqual(second.id, 0)
        XCTAssertTrue(first.payload.hasSuffix("\n"))
    }

    func testJoystickAnglesTolerateSlopAndWrap() {
        XCTAssertEqual(MicroKeyMap.joystickDirection(angle: 0.02), .right)
        XCTAssertEqual(MicroKeyMap.joystickDirection(angle: 0.98), .right)
        XCTAssertEqual(MicroKeyMap.joystickDirection(angle: -0.02), .right)
        XCTAssertEqual(MicroKeyMap.joystickDirection(angle: 0.27), .down)
        XCTAssertEqual(MicroKeyMap.joystickDirection(angle: 0.48), .left)
        XCTAssertNil(MicroKeyMap.joystickDirection(angle: 0.125))
    }

    func testLightingOnlyEmitsChangedSlots() {
        var lighting = MicroLighting()
        let initial = lighting.changes(
            for: [.idle, .working, .blocked, .done, nil, .idle]
        )
        XCTAssertEqual(initial.map(\.id), [0, 1, 2, 3, 4, 5])
        // `e` is the numeric OAILightingEffect, not an effect name.
        XCTAssertEqual(initial[1].e, MicroLightingEffect.breath.rawValue)
        XCTAssertEqual(initial[1].e, 4)
        XCTAssertEqual(lighting.changes(
            for: [.idle, .working, .blocked, .done, nil, .idle]
        ), [])
        let changed = lighting.changes(
            for: [.idle, .done, .blocked, .done, nil, nil]
        )
        XCTAssertEqual(changed.map(\.id), [1, 5])
        XCTAssertEqual(changed[1].e, MicroLightingEffect.off.rawValue)
        XCTAssertEqual(changed[1].b, 0)
    }

    // MARK: - Captured from real hardware (serial 441BF6D10968, 2026-07-26)

    func testCommandKeyACT11IsRecognised() {
        // Seven contiguous command ids, ACT06...ACT12. Public write-ups list six
        // and omit ACT11; the pad emits it.
        XCTAssertEqual(MicroKeyMap.commandIDs.count, 7)
        XCTAssertEqual(
            MicroRPCDecoder.decodePayload(
                #"{"m":"v.oai.hid","p":{"k":"ACT11","act":1}}"#
            ),
            .commandKey(id: "ACT11", state: .press)
        )
    }

    func testDialPressReportsAsENC_CLK() {
        XCTAssertEqual(
            MicroRPCDecoder.decodePayload(
                #"{"m":"v.oai.hid","p":{"k":"ENC_CLK","act":1}}"#
            ),
            .encoder(.press)
        )
        XCTAssertEqual(
            MicroRPCDecoder.decodePayload(
                #"{"m":"v.oai.hid","p":{"k":"ENC_CLK","act":0}}"#
            ),
            .encoder(.release)
        )
    }

    func testJoystickDecodesAsRawSample() {
        XCTAssertEqual(
            MicroRPCDecoder.decodePayload(
                #"{"m":"v.oai.rad","p":{"a":0.759925,"d":0.750131}}"#
            ),
            .joystickSample(angle: 0.759925, distance: 0.750131)
        )
    }

    /// Replays the exact sample stream captured while pushing the stick up and
    /// then right. The old distance==1/distance==0 rule produced a spurious
    /// "up press" followed by a "right release" from these very samples.
    func testJoystickTrackerDerivesEdgesFromCapturedStream() {
        var tracker = MicroKeyMap.MicroJoystickTracker()
        var edges: [(MicroJoystickDirection, MicroPressState)] = []
        let captured: [(Double, Double)] = [
            (0.779791, 0.121487),   // drifting off centre — below threshold
            (0.761204, 0.652704),   // up, crosses press threshold
            (0.759925, 0.750131),
            (0.758927, 0.771655),
            (0.759291, 0.803436),
            (0.004516, 0.340005),   // recentring through right, below release
            (0.002211, 0.919663),   // right, held
            (0.009598, 0.171501),   // back to centre
        ]
        for (angle, distance) in captured {
            edges.append(contentsOf: tracker.update(angle: angle, distance: distance))
        }
        XCTAssertEqual(
            edges.map { "\($0.0)-\($0.1)" },
            ["up-press", "up-release", "right-press", "right-release"]
        )
        XCTAssertNil(tracker.heldDirection)
    }

    func testJoystickTrackerLatchesDirectionForRelease() {
        var tracker = MicroKeyMap.MicroJoystickTracker()
        _ = tracker.update(angle: 0.75, distance: 0.9)
        XCTAssertEqual(tracker.heldDirection, .up)
        // Recentring passes through other angles; the release must still be
        // attributed to the direction that was actually held.
        let edges = tracker.update(angle: 0.25, distance: 0.1)
        XCTAssertEqual(edges.map { "\($0.direction)-\($0.state)" }, ["up-release"])
    }

    func testJoystickTrackerHysteresisIgnoresJitter() {
        var tracker = MicroKeyMap.MicroJoystickTracker()
        XCTAssertTrue(tracker.update(angle: 0, distance: 0.5).isEmpty)
        XCTAssertEqual(tracker.update(angle: 0, distance: 0.7).count, 1)
        // Between the release and press thresholds: no event, still held.
        XCTAssertTrue(tracker.update(angle: 0, distance: 0.5).isEmpty)
        XCTAssertEqual(tracker.heldDirection, .right)
    }

    func testSlotAssignmentRanksByAttentionAndCapsAtSix() {
        var assigner = MicroSlotAssigner()
        // blocked > done > working > idle; ties keep sidebar order. With seven
        // panes the lone extra idle pane (g) is the one pushed off the keys.
        let first = assigner.update([
            .init(paneID: "a", status: .working),
            .init(paneID: "b", status: .blocked),
            .init(paneID: "c", status: .idle),
            .init(paneID: "d", status: .done),
            .init(paneID: "e", status: .working),
            .init(paneID: "f", status: .blocked),
            .init(paneID: "g", status: .idle),
        ])
        XCTAssertEqual(
            first.compactMap { $0?.paneID },
            ["b", "f", "d", "a", "e", "c"]
        )

        // Attention-first reorders regardless of input order.
        let reordered = assigner.update([
            .init(paneID: "c", status: .working),
            .init(paneID: "a", status: .done),
            .init(paneID: "b", status: .blocked),
        ])
        XCTAssertEqual(reordered.compactMap { $0?.paneID }, ["b", "a", "c"])
        XCTAssertEqual(reordered[0]?.status, .blocked)
    }

    func testBlockedAgentKeepsKeyAgainstSixWorkingOnes() {
        var assigner = MicroSlotAssigner()
        let slots = assigner.update(
            (1...6).map { .init(paneID: "w\($0)", status: .working) }
                + [.init(paneID: "blk", status: .blocked)]
        )
        let ids = slots.compactMap { $0?.paneID }
        XCTAssertEqual(ids.first, "blk")
        XCTAssertFalse(ids.contains("w6"))
    }

    func testFocusedPaneIsBoostedAboveIdlePanes() {
        var assigner = MicroSlotAssigner()
        let slots = assigner.update(
            [
                .init(paneID: "i1", status: .idle),
                .init(paneID: "i2", status: .idle),
                .init(paneID: "sel", status: .idle),
                .init(paneID: "w1", status: .working),
                .init(paneID: "w2", status: .working),
                .init(paneID: "w3", status: .working),
                .init(paneID: "w4", status: .working),
            ],
            selectedPaneID: "sel"
        )
        let ids = slots.compactMap { $0?.paneID }
        // The focused idle pane is boosted to the working tier and keeps its key;
        // an unfocused idle pane is what overflows instead.
        XCTAssertTrue(ids.contains("sel"))
        XCTAssertFalse(ids.contains("i2"))
    }

    func testOnlyNeedsYouFilterThenRanks() {
        var assigner = MicroSlotAssigner()
        let filtered = assigner.update(
            [
                .init(paneID: "a", status: .idle),
                .init(paneID: "b", status: .blocked),
                .init(paneID: "c", status: .done),
            ],
            selectedPaneID: "a",
            onlyNeedsYou: true
        )
        // Only blocked panes and the focused pane survive the filter; the done
        // pane (c) is dropped. The survivors are then ranked blocked-first.
        XCTAssertEqual(filtered.compactMap { $0?.paneID }, ["b", "a"])
    }

    func testMockTransportRecordsAndInjectsReports() throws {
        let transport = MockMicroTransport()
        let report = try XCTUnwrap(MicroFraming.encode("{}").first)
        let received = expectation(description: "received")
        transport.onReport = { value in
            XCTAssertEqual(value, report)
            received.fulfill()
        }
        try transport.open()
        try transport.send(report: report)
        transport.inject(report)
        XCTAssertEqual(transport.sentReports, [report])
        wait(for: [received], timeout: 0.1)
    }

    func testRankingMirrorsHardwareVerifiedUSBAndBLECollections() {
        let usbPairs = [
            MicroUsagePair(usagePage: 1, usage: 6),
            MicroUsagePair(usagePage: 12, usage: 1),
            MicroUsagePair(usagePage: 1, usage: 2),
            MicroUsagePair(usagePage: 1, usage: 1),
            MicroUsagePair(usagePage: 1, usage: 5),
            MicroUsagePair(usagePage: 0xFF00, usage: 1),
        ]
        let blePairs = [
            MicroUsagePair(usagePage: 1, usage: 6),
            MicroUsagePair(usagePage: 12, usage: 1),
            MicroUsagePair(usagePage: 12, usage: 2),
            MicroUsagePair(usagePage: 0xFF00, usage: 1),
        ]
        let usb = identity(
            id: 900, pairs: usbPairs, transport: .usb, product: "Codex Micro"
        )
        let ble = identity(id: 901, pairs: blePairs)

        XCTAssertTrue(usb.hasVendorCollection)
        XCTAssertTrue(ble.hasVendorCollection)
        XCTAssertEqual(usb.usagePairs, usbPairs)
        XCTAssertEqual(ble.usagePairs, blePairs)
        XCTAssertEqual(IOHIDMicroTransport.ranked([ble, usb]), [usb, ble])
    }

    func testRankingThreeBLENodesPrefersVendorThenReportSizesThenStableID() {
        let keyboardOnly = identity(
            id: 1,
            pairs: [MicroUsagePair(usagePage: 1, usage: 6)]
        )
        let vendorWrongSizes = identity(
            id: 2,
            pairs: [MicroUsagePair(usagePage: 0xFF00, usage: 1)],
            input: 32,
            output: 64
        )
        let reportSixNode = identity(
            id: 30,
            pairs: [
                MicroUsagePair(usagePage: 1, usage: 6),
                MicroUsagePair(usagePage: 12, usage: 1),
                MicroUsagePair(usagePage: 12, usage: 2),
                MicroUsagePair(usagePage: 0xFF00, usage: 1),
            ]
        )

        XCTAssertEqual(
            IOHIDMicroTransport.ranked([
                keyboardOnly, reportSixNode, vendorWrongSizes,
            ]),
            [reportSixNode, vendorWrongSizes, keyboardOnly]
        )
    }

    func testRankingTieBreakNeverDependsOnInputOrder() {
        let higherID = identity(
            id: 42,
            pairs: [MicroUsagePair(usagePage: 0xFF00, usage: 1)]
        )
        let lowerID = identity(
            id: 7,
            pairs: [MicroUsagePair(usagePage: 0xFF00, usage: 1)]
        )

        XCTAssertEqual(
            IOHIDMicroTransport.ranked([higherID, lowerID]),
            [lowerID, higherID]
        )
        XCTAssertEqual(
            IOHIDMicroTransport.ranked([lowerID, higherID]),
            [lowerID, higherID]
        )
    }
}
