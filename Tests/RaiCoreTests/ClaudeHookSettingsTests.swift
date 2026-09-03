import RaiCore
import XCTest

final class ClaudeHookSettingsTests: XCTestCase {
    private let scriptPath = "/Users/test/Library/Application Support/Rai/rai-hook.sh"

    func testMergeIsIdempotentAndPreservesExistingHooks() throws {
        let original = try fixture(named: "hook-settings-existing")
        let first = try ClaudeHookSettings.merged(
            settings: original,
            scriptPath: scriptPath
        )
        let second = try ClaudeHookSettings.merged(
            settings: first,
            scriptPath: scriptPath
        )

        XCTAssertEqual(first, second)
        let root = try object(first)
        XCTAssertEqual(root["model"] as? String, "sonnet")
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        let preToolUse = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        XCTAssertTrue(preToolUse.contains { group in
            let handlers = group["hooks"] as? [[String: Any]]
            return handlers?.contains {
                ($0["command"] as? String) == "/Users/test/bin/check-command.sh"
            } == true
        })
        for event in ClaudeHookSettings.events {
            let groups = try XCTUnwrap(hooks[event] as? [[String: Any]])
            let command = ClaudeHookSettings.hookCommand(
                scriptPath: scriptPath,
                event: event
            )
            XCTAssertEqual(commandCount(command, in: groups), 1)
            let raiHandler = groups
                .compactMap { $0["hooks"] as? [[String: Any]] }
                .flatMap { $0 }
                .first { ($0["command"] as? String) == command }
            XCTAssertEqual(
                raiHandler?["timeout"] as? Int,
                event == "PermissionRequest" ? 60 : 2
            )
            XCTAssertEqual(raiHandler?["async"] as? Bool, event == "PermissionRequest" ? nil : true)
        }
    }

    func testRemoveDeletesOnlyRaiHandlers() throws {
        let original = try fixture(named: "hook-settings-existing")
        let merged = try ClaudeHookSettings.merged(
            settings: original,
            scriptPath: scriptPath
        )
        let removed = try ClaudeHookSettings.removing(
            settings: merged,
            scriptPath: scriptPath
        )

        XCTAssertEqual(
            try object(removed) as NSDictionary,
            try object(original) as NSDictionary
        )
    }

    func testMergePreservesFixtureWithoutHooks() throws {
        let original = try fixture(named: "hook-settings-empty")
        let merged = try ClaudeHookSettings.merged(
            settings: original,
            scriptPath: scriptPath
        )
        let root = try object(merged)
        XCTAssertNotNil(root["permissions"])
        XCTAssertNotNil(root["hooks"])
    }

    func testChangingHoldReplacesPermissionHandler() throws {
        let first = try ClaudeHookSettings.merged(
            settings: nil,
            scriptPath: scriptPath,
            decisionHoldSeconds: 45
        )
        let second = try ClaudeHookSettings.merged(
            settings: first,
            scriptPath: scriptPath,
            decisionHoldSeconds: 60
        )
        let hooks = try XCTUnwrap(try object(second)["hooks"] as? [String: Any])
        let groups = try XCTUnwrap(hooks["PermissionRequest"] as? [[String: Any]])
        let handlers = groups.compactMap { $0["hooks"] as? [[String: Any]] }.flatMap { $0 }
        XCTAssertEqual(handlers.count, 1)
        XCTAssertEqual(handlers[0]["timeout"] as? Int, 75)
        XCTAssertEqual(
            handlers[0]["command"] as? String,
            ClaudeHookSettings.hookCommand(
                scriptPath: scriptPath,
                event: "PermissionRequest",
                decisionHoldSeconds: 60
            )
        )
    }

    func testPermissionTimeoutOrderingLeavesTwoProcessingMargins() throws {
        let hold = 37
        let hookRead = ClaudeHookSettings.hookReadTimeout(forHoldSeconds: hold)
        let claude = ClaudeHookSettings.claudeTimeout(forHoldSeconds: hold)
        let merged = try ClaudeHookSettings.merged(
            settings: nil,
            scriptPath: scriptPath,
            decisionHoldSeconds: hold
        )
        let hooks = try XCTUnwrap(try object(merged)["hooks"] as? [String: Any])
        let groups = try XCTUnwrap(hooks["PermissionRequest"] as? [[String: Any]])
        let handler = try XCTUnwrap(
            groups.compactMap { $0["hooks"] as? [[String: Any]] }.flatMap { $0 }.first
        )

        XCTAssertEqual(hookRead, 47)
        XCTAssertEqual(claude, 52)
        XCTAssertLessThan(hold, hookRead)
        XCTAssertLessThan(hookRead, claude)
        XCTAssertEqual(handler["timeout"] as? Int, claude)
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = try String(
            contentsOf: root.appendingPathComponent("Resources/rai-hook.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(script.contains("float(sys.argv[2]) + 10.0"))
    }

    private func fixture(named name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: name,
                withExtension: "json",
                subdirectory: "Fixtures"
            )
        )
        return try Data(contentsOf: url)
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private func commandCount(
        _ command: String,
        in groups: [[String: Any]]
    ) -> Int {
        groups.reduce(into: 0) { count, group in
            let handlers = group["hooks"] as? [[String: Any]] ?? []
            count += handlers.filter { ($0["command"] as? String) == command }.count
        }
    }
}
