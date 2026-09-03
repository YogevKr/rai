import RaiCore
import XCTest

final class AgentBeaconTests: XCTestCase {
    func testBeaconDecodesDocumentedHookFieldsAndBoundsToolInput() throws {
        let content = String(repeating: "x", count: 80_000)
        let data = try JSONSerialization.data(withJSONObject: [
            "event": "PermissionRequest",
            "pane_id": "w1:p2",
            "herdr_socket_path": "/tmp/herdr.sock",
            "session_id": "session-1",
            "cwd": "/repo",
            "transcript_path": "/tmp/session.jsonl",
            "tool_name": "Write",
            "tool_input": ["file_path": "/repo/a.swift", "content": content],
            "last_assistant_message": content + "\nfinal line",
            "ts": 1_780_000_000,
            "parent_pid": 4321,
        ])

        let beacon = try JSONDecoder().decode(AgentBeacon.self, from: data)

        XCTAssertEqual(beacon.event, "PermissionRequest")
        XCTAssertEqual(beacon.paneID, "w1:p2")
        XCTAssertEqual(beacon.herdrSocketPath, "/tmp/herdr.sock")
        XCTAssertEqual(beacon.sessionID, "session-1")
        XCTAssertEqual(beacon.parentPID, 4321)
        XCTAssertEqual(beacon.pendingSummary, "Write: /repo/a.swift")
        XCTAssertEqual(beacon.completionSummary, nil)
        XCTAssertLessThanOrEqual(
            beacon.lastAssistantMessage?.utf8.count ?? 0,
            AgentBeacon.maximumMessageBytes
        )
        XCTAssertTrue(beacon.lastAssistantMessage?.hasSuffix("final line") == true)
        XCTAssertLessThanOrEqual(
            try JSONEncoder().encode(beacon.toolInput).count,
            AgentBeacon.maximumToolInputBytes
        )
    }

    func testAskUserQuestionUsesFirstQuestion() {
        let beacon = AgentBeacon(
            event: "PreToolUse",
            sessionID: "session-1",
            cwd: "/repo",
            transcriptPath: "/tmp/session.jsonl",
            toolName: "AskUserQuestion",
            toolInput: .object([
                "questions": .array([
                    .object([
                        "question": .string("Which target should I test?"),
                        "options": .array([
                            .object(["label": .string("Mac")]),
                            .object(["label": .string("iOS")]),
                        ]),
                    ]),
                ]),
            ]),
            timestamp: 1
        )

        XCTAssertEqual(beacon.pendingSummary, "Which target should I test?")
    }

    func testPermissionNotificationInheritsLatestTool() {
        let tool = AgentBeacon(
            event: "PreToolUse",
            sessionID: "session-1",
            cwd: "/repo",
            transcriptPath: "/tmp/session.jsonl",
            toolName: "Bash",
            toolInput: .object(["command": .string("swift test\n--filter Beacon")]),
            timestamp: 1
        )
        let notification = AgentBeacon(
            event: "Notification",
            sessionID: "session-1",
            cwd: "/repo",
            transcriptPath: "/tmp/session.jsonl",
            notificationType: "permission_prompt",
            message: "Claude needs your permission",
            timestamp: 2
        )

        XCTAssertEqual(
            notification.inheritingTool(from: tool).pendingSummary,
            "Bash: swift test"
        )
    }

    func testPushBodyUsesBeaconAndFallback() {
        let permission = AgentBeacon(
            event: "PermissionRequest",
            sessionID: "session-1",
            cwd: "/repo",
            transcriptPath: "/tmp/session.jsonl",
            toolName: "WebFetch",
            toolInput: .object(["url": .string("https://example.com/reference")]),
            timestamp: 1
        )
        let stop = AgentBeacon(
            event: "Stop",
            sessionID: "session-1",
            cwd: "/repo",
            transcriptPath: "/tmp/session.jsonl",
            lastAssistantMessage: "First line\n\nThe final result",
            timestamp: 2
        )

        XCTAssertEqual(
            AgentNotificationBody.compose(status: .blocked, beacon: permission),
            "WebFetch: https://example.com/…"
        )
        XCTAssertEqual(
            AgentNotificationBody.compose(status: .done, beacon: stop),
            "The final result"
        )
        XCTAssertEqual(
            AgentNotificationBody.compose(status: .blocked, beacon: nil),
            "Needs you"
        )
        XCTAssertEqual(
            AgentNotificationBody.compose(status: .done, beacon: nil),
            "Finished"
        )
    }

    func testCompletionBodyRedactsBareCredentials() {
        let awsKey = "AKIAIOSFODNN7EXAMPLE"
        let stop = AgentBeacon(
            event: "Stop",
            sessionID: "session-1",
            cwd: "/repo",
            transcriptPath: "/tmp/session.jsonl",
            lastAssistantMessage: "Deployed with \(awsKey)",
            timestamp: 1
        )

        let body = AgentNotificationBody.compose(status: .done, beacon: stop)

        XCTAssertEqual(body, "Deployed with <redacted>")
        XCTAssertFalse(body.contains(awsKey))
    }

    func testCompletionBodySuppressesOpaqueCredentials() {
        let credential = "clientSecret0123456789ABCDEFGHIJ"
        let stop = AgentBeacon(
            event: "Stop",
            sessionID: "session-1",
            cwd: "/repo",
            transcriptPath: "/tmp/session.jsonl",
            lastAssistantMessage: "Saved \(credential)",
            timestamp: 1
        )

        XCTAssertEqual(
            AgentNotificationBody.compose(status: .done, beacon: stop),
            "Sensitive completion details redacted"
        )
    }

    func testCompletionBodySuppressesCredentialPhrases() {
        let stop = AgentBeacon(
            event: "Stop",
            sessionID: "session-1",
            cwd: "/repo",
            transcriptPath: "/tmp/session.jsonl",
            lastAssistantMessage: "The password is hunter2",
            timestamp: 1
        )

        XCTAssertEqual(
            AgentNotificationBody.compose(status: .done, beacon: stop),
            "Sensitive completion details redacted"
        )
    }

    func testNotificationBodyHidesURLSecrets() {
        let permission = AgentBeacon(
            event: "PermissionRequest",
            sessionID: "session-1",
            cwd: "/repo",
            transcriptPath: "/tmp/session.jsonl",
            toolName: "WebFetch",
            toolInput: .object([
                "url": .string(
                    "https://example.test/run?X-Goog-Signature=top-secret-value"
                ),
            ]),
            timestamp: 1
        )

        let body = AgentNotificationBody.compose(status: .blocked, beacon: permission)

        XCTAssertEqual(body, "WebFetch: https://example.test/…")
        XCTAssertFalse(body.contains("top-secret-value"))
    }

    func testBashSummaryHidesUnrecognizedArguments() {
        let permission = AgentBeacon(
            event: "PermissionRequest",
            sessionID: "session-1",
            cwd: "/repo",
            transcriptPath: "/tmp/session.jsonl",
            toolName: "Bash",
            toolInput: .object([
                "command": .string("redis-cli -a hunter2"),
            ]),
            timestamp: 1
        )

        let body = AgentNotificationBody.compose(status: .blocked, beacon: permission)

        XCTAssertEqual(body, "Bash: redis-cli …")
        XCTAssertFalse(body.contains("hunter2"))
    }

    func testDecisionBodyShowsDirectFileCommand() {
        let permission = AgentBeacon(
            event: "PermissionRequest",
            sessionID: "session-1",
            cwd: "/repo",
            transcriptPath: "/tmp/session.jsonl",
            toolName: "Bash",
            toolInput: .object(["command": .string("touch allow-created")]),
            timestamp: 1
        )

        XCTAssertEqual(
            AgentNotificationBody.composeDecision(beacon: permission),
            "Bash: touch allow-created"
        )
    }

    func testDecisionBodyHidesUnrecognizedCommandArguments() {
        let permission = AgentBeacon(
            event: "PermissionRequest",
            sessionID: "session-1",
            cwd: "/repo",
            transcriptPath: "/tmp/session.jsonl",
            toolName: "Bash",
            toolInput: .object(["command": .string("redis-cli -a hunter2")]),
            timestamp: 1
        )

        let body = AgentNotificationBody.composeDecision(beacon: permission)

        XCTAssertEqual(body, "Bash: redis-cli …")
        XCTAssertFalse(body.contains("hunter2"))
    }

    func testDecisionBodyHidesURLPathSecrets() {
        let permission = AgentBeacon(
            event: "PermissionRequest",
            sessionID: "session-1",
            cwd: "/repo",
            transcriptPath: "/tmp/session.jsonl",
            toolName: "WebFetch",
            toolInput: .object([
                "url": .string("https://hooks.slack.test/services/secret/value"),
            ]),
            timestamp: 1
        )

        let body = AgentNotificationBody.composeDecision(beacon: permission)

        XCTAssertEqual(body, "WebFetch: https://hooks.slack.test/…")
        XCTAssertFalse(body.contains("secret"))
    }

    func testDecisionBodyHidesURLInsideAFileCommand() {
        let permission = AgentBeacon(
            event: "PermissionRequest",
            sessionID: "session-1",
            cwd: "/repo",
            transcriptPath: "/tmp/session.jsonl",
            toolName: "Bash",
            toolInput: .object([
                "command": .string(
                    "ln -s https://hooks.example/services/secret/value link"
                ),
            ]),
            timestamp: 1
        )

        let body = AgentNotificationBody.composeDecision(beacon: permission)

        XCTAssertEqual(body, "Bash: ln …")
        XCTAssertFalse(body.contains("secret"))
    }

    func testPermissionPushRedactorRejectsCredentialLikeText() {
        let samples = [
            "WebSearch: password hunter2",
            "Bash: export TOKEN=abc123secret",
            "Bash: curl -H Authorization:BearerSecret123 example.test",
            "WebSearch: code 1234",
        ]

        for sample in samples {
            XCTAssertEqual(
                PushTextRedactor.permission(sample, agent: "Claude"),
                "Permission request from Claude"
            )
        }
        let url = PushTextRedactor.permission(
            "WebFetch: https://example.test/run?query=hunter2",
            agent: "WebFetch"
        )
        XCTAssertEqual(url, "WebFetch: https://example.test/run?query=•••")

        let beacon = AgentBeacon(
            event: "PermissionRequest",
            sessionID: "session-1",
            cwd: "/repo",
            transcriptPath: "/tmp/transcript.jsonl",
            toolName: "WebSearch",
            toolInput: .object(["query": .string("password hunter2")]),
            timestamp: 1
        )
        XCTAssertEqual(
            AgentNotificationBody.composeDecision(beacon: beacon),
            "Permission request from Claude"
        )
    }

    func testPermissionPushRedactorKeepsOrdinaryFourDigitText() {
        let samples = [
            "WebSearch: WWDC 2026",
            "Write: /tmp/1234/output",
            "WebSearch: v2026 release notes",
        ]

        for sample in samples {
            XCTAssertEqual(
                PushTextRedactor.permission(sample, agent: "Claude"),
                sample
            )
        }
        XCTAssertEqual(
            PushTextRedactor.permission("Bash: code is 1234", agent: "Claude"),
            "Permission request from Claude"
        )
        XCTAssertEqual(
            PushTextRedactor.permission("WebSearch: issue 123456", agent: "Claude"),
            "WebSearch: issue •••"
        )
    }

    func testPermissionPushRedactorClassifiesPunctuatedTokenCores() {
        let fixtures = [
            ("123456.", "•••."),
            ("(123456)", "(•••)"),
            ("'123456'", "'•••'"),
            ("123456,", "•••,"),
            ("2.1.259", "2.1.259"),
            ("#1140", "#1140"),
        ]

        for (input, expected) in fixtures {
            XCTAssertEqual(
                PushTextRedactor.permission(input, agent: "Claude"),
                expected
            )
        }
    }

    func testPermissionPushRedactorKeepsOnlyRealPathShapedSlashTokens() {
        let base64 = "c2VjcmV0/2NyZWRlbnRpYWw="
        let prefixedSecret = "sk-live/abcdefghijklmnopqrstuvwxyz"
        let path = "/Users/x/repos/a-b/file.swift"

        XCTAssertEqual(PushTextRedactor.permission(base64, agent: "Claude"), "•••")
        XCTAssertEqual(PushTextRedactor.permission(prefixedSecret, agent: "Claude"), "•••")
        XCTAssertEqual(PushTextRedactor.permission(path, agent: "Claude"), path)
    }

    func testOrdinaryPreToolUseIsContextNotAPendingRequest() {
        let beacon = AgentBeacon(
            event: "PreToolUse",
            sessionID: "session-1",
            cwd: "/repo",
            transcriptPath: "/tmp/session.jsonl",
            toolName: "Bash",
            toolInput: .object(["command": .string("swift test")]),
            timestamp: 1
        )

        XCTAssertNil(beacon.pendingSummary)
    }

    func testPaneCorrelationUsesDirectIDThenCWDThenProcessAncestry() {
        let direct = beacon(paneID: "w1:p2", cwd: "/shared")
        let candidates = [
            BeaconPaneCandidate(
                paneID: "w1:p1",
                cwd: "/shared",
                shellPID: 100,
                processIDs: [110]
            ),
            BeaconPaneCandidate(
                paneID: "w1:p2",
                cwd: "/shared",
                shellPID: 200,
                processIDs: [210]
            ),
        ]
        XCTAssertEqual(
            AgentBeaconCorrelator.paneID(for: direct, candidates: candidates),
            "w1:p2"
        )

        let uniqueCWD = beacon(cwd: "/tmp/../repo")
        XCTAssertEqual(
            AgentBeaconCorrelator.paneID(
                for: uniqueCWD,
                candidates: [BeaconPaneCandidate(paneID: "w2:p1", cwd: "/repo")]
            ),
            "w2:p1"
        )

        let fallback = beacon(cwd: "/shared")
        XCTAssertEqual(
            AgentBeaconCorrelator.paneID(
                for: fallback,
                candidates: candidates,
                parentChain: [999, 210, 200, 1]
            ),
            "w1:p2"
        )
        XCTAssertNil(
            AgentBeaconCorrelator.paneID(for: fallback, candidates: candidates)
        )
        XCTAssertNil(
            AgentBeaconCorrelator.paneID(
                for: uniqueCWD,
                candidates: [BeaconPaneCandidate(paneID: "w2:p1", cwd: "/repo")],
                parentChain: [999]
            )
        )
    }

    private func beacon(paneID: String? = nil, cwd: String) -> AgentBeacon {
        AgentBeacon(
            event: "PreToolUse",
            paneID: paneID,
            sessionID: "session-1",
            cwd: cwd,
            transcriptPath: "/tmp/session.jsonl",
            timestamp: 1
        )
    }
}
