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
