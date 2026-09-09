import XCTest
@testable import RaiCore

final class EndpointMetadataTests: XCTestCase {
    private func fixture() throws -> HerdrEndpointSnapshot {
        try JSONDecoder().decode(HerdrEndpointSnapshot.self, from: Data(#"""
        {"boot_id":"metadata-lab","revision":1,"workspaces":[
          {"workspace_id":"w1","label":"Repo","branch":"feature/full-text","agent_status":"working",
           "git_ahead_behind":[2,1],"tokens":[["model","workspace model"],["cost","90"]]}],
         "tabs":[{"workspace_id":"w1","tab_id":"w1:t1","label":"Build","custom_label":true}],
         "panes":[{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p1","label":"Shell"}],
         "agents":[{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p1","agent":"codex",
          "display_agent":"Codex display","name":"agent name","title":"Agent pane","agent_status":"working",
          "state_labels":[["working","Thinking"]],"tokens":[["model","agent model"],["terminal_title","custom title"]],
          "terminal_title":"⠋ raw title","terminal_title_stripped":"raw title"}]}
        """#.utf8))
    }

    func testAccessibleDefaultStatusUsesWordsWithoutChangingVisibleRows() throws {
        let snapshot = try fixture()
        for (status, icon) in [("working", "●"), ("blocked", "!"), ("done", "✓"), ("idle", "○"), ("unknown", "?")] {
            let record: JSONValue = .object(["label": .string("Repo"), "agent_status": .string(status)])
            let rows = EndpointMetadataResolver.rows(record: record, kind: .workspace,
                snapshot: snapshot, configuration: .init())
            XCTAssertEqual(rows.flatMap { $0 }.map(\.text), [icon, "Repo"])
            XCTAssertEqual(EndpointMetadataResolver.accessibilityLabel(record: record, rows: rows), "\(status), Repo")
        }
    }

    func testAccessibleAgentStatusUsesCustomServerLabel() throws {
        let snapshot = try fixture()
        let record = try XCTUnwrap(snapshot.agents.first)
        let rows = EndpointMetadataResolver.rows(record: record, kind: .agent,
            snapshot: snapshot, configuration: .init())
        XCTAssertEqual(EndpointMetadataResolver.accessibilityLabel(record: record, rows: rows),
                       "Thinking, Repo, Build, Codex display")
    }

    func testAccessibleExplicitStatusOmitsTheDuplicateIconLabelAcrossRows() throws {
        let snapshot = try fixture()
        let record: JSONValue = .object(["label": .string("Repo"), "agent_status": .string("blocked"),
            "state_labels": .array([.array([.string("blocked"), .string("מחכה")])])])
        var configuration = EndpointMetadataConfiguration()
        configuration[.workspace].rows = [[.init("state_icon"), .init("workspace")], [.init("state_text")]]
        let rows = EndpointMetadataResolver.rows(record: record, kind: .workspace,
            snapshot: snapshot, configuration: configuration)
        XCTAssertEqual(rows.flatMap { $0 }.map(\.text), ["!", "Repo", "מחכה"])
        XCTAssertEqual(EndpointMetadataResolver.accessibilityLabel(record: record, rows: rows), "Repo, מחכה")
        configuration[.workspace].rows = [[.init("workspace")]]
        let withoutStatus = EndpointMetadataResolver.rows(record: record, kind: .workspace,
            snapshot: snapshot, configuration: configuration)
        XCTAssertEqual(EndpointMetadataResolver.accessibilityLabel(record: record, rows: withoutStatus), "Repo")
    }

    func testOrderedRuleStopsWithoutStyleAndFalseRemovesModifiers() throws {
        let token = try JSONDecoder().decode(EndpointMetadataToken.self, from: Data(#"""
        {"token":"workspace","bold":true,"dim":true,"fg":"#f00","rules":[
         {"contains":"Repo","bold":false},{"equals":"Repo","fg":"#0f0","dim":false}]}
        """#.utf8))
        XCTAssertEqual(token.resolvedStyle(for: "Repo"), .init(fg: "#f00", bold: false, dim: true))
        var stopped = token
        stopped.rules.insert(.init(condition: .equals, value: "Repo"), at: 0)
        XCTAssertEqual(stopped.resolvedStyle(for: "Repo"), token.style)
        XCTAssertEqual(token.resolvedStyle(for: "Other"), token.style)
    }

    func testASCIIOnlyCaseFoldingForEachTextCondition() {
        for condition in [EndpointMetadataRule.Condition.equals, .contains, .startsWith] {
            let rule = EndpointMetadataRule(condition: condition, value: "ÉA", ignoreCase: true)
            XCTAssertTrue(rule.matches("Éa"))
            XCTAssertFalse(rule.matches("éa"))
            XCTAssertFalse(rule.matches("E\u{301}a"))
        }
        XCTAssertTrue(EndpointMetadataRule(condition: .contains, value: "").matches("anything"))
        XCTAssertFalse(EndpointMetadataRule(condition: .equals, value: "Local").matches("local"))
        XCTAssertTrue(EndpointMetadataRule(condition: .startsWith, value: "Local", ignoreCase: true).matches("LOCALhost"))
        XCTAssertFalse(EndpointMetadataRule(condition: .startsWith, value: "Local", ignoreCase: true).matches("myLocal"))
    }

    func testNumericRulesRejectPartialNonfiniteAndWhitespaceValues() throws {
        let rule = EndpointMetadataRule(condition: .greaterThan, value: "80")
        for value in ["90", "8.1e1", "+90", "80.01"] { XCTAssertTrue(rule.matches(value), value) }
        for value in ["80", "70", "90%", " 90", "90 ", "90\n", "NaN", "inf", "-inf", "1e999", "", "９０", "0x1p8", "1_000"] {
            XCTAssertFalse(rule.matches(value), value)
        }
        XCTAssertTrue(EndpointMetadataRule(condition: .lessThan, value: "80").matches("-90"))
        XCTAssertThrowsError(try EndpointMetadataRule(condition: .greaterThan, value: "80", ignoreCase: false).validate())
        XCTAssertThrowsError(try EndpointMetadataRule(condition: .lessThan, value: "inf").validate())
    }

    func testWireRulesRejectInvalidConditionCountsTypesAndUnknownFields() {
        for json in [#"{}"#, #"{"equals":"a","contains":"b"}"#, #"{"gt":"80"}"#,
                     #"{"lt":80,"ignore_case":false}"#, #"{"equals":"a","bold":"true"}"#,
                     #"{"equals":"a","unexpected":true}"#, #"{"equals":"a","fg":"blue"}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(EndpointMetadataRule.self, from: Data(json.utf8)), json)
        }
    }

    func testColorValidationAndExpansion() throws {
        XCTAssertEqual(EndpointMetadataStyle.rgb("#aF0"), 0xaaff00)
        XCTAssertEqual(EndpointMetadataStyle.rgb("#12Ab90"), 0x12ab90)
        for value in ["red", "fff", "#12", "#1234", "#12345678", "#ggg", " #fff", "#ＦＦＦ"] {
            XCTAssertThrowsError(try EndpointMetadataStyle(fg: value).validate(), value)
        }
    }

    func testTokenLimitsAndBuiltinRules() throws {
        for kind in EndpointMetadataKind.allCases {
            for token in kind.tokens { XCTAssertNoThrow(try EndpointMetadataToken(token).validate(kind: kind)) }
            for token in ["$model", "$a_9-z", "$" + String(repeating: "x", count: 32)] {
                XCTAssertNoThrow(try EndpointMetadataToken(token).validate(kind: kind))
            }
            for token in ["$", "$é", "$a.b", "$" + String(repeating: "x", count: 33), "unknown"] {
                XCTAssertThrowsError(try EndpointMetadataToken(token).validate(kind: kind))
            }
        }
        for token in ["state_icon", "git_status"] {
            XCTAssertThrowsError(try EndpointMetadataToken(token, rules: [.init()]).validate(kind: .workspace))
        }
        XCTAssertThrowsError(try EndpointMetadataToken("agent").validate(kind: .workspace))
        XCTAssertThrowsError(try EndpointMetadataToken("workspace", rules: Array(repeating: .init(), count: 17)).validate(kind: .agent))
        XCTAssertNoThrow(try EndpointMetadataToken("workspace", rules: Array(repeating: .init(), count: 16)).validate(kind: .agent))
    }

    func testLayoutLimitsAndCanonicalOverrides() throws {
        let row = Array(repeating: EndpointMetadataToken("workspace"), count: 16)
        XCTAssertNoThrow(try EndpointMetadataLayout(rows: Array(repeating: row, count: 16)).validate(kind: .agent))
        XCTAssertThrowsError(try EndpointMetadataLayout(rows: Array(repeating: row, count: 17)).validate(kind: .agent))
        XCTAssertThrowsError(try EndpointMetadataLayout(rows: [row + [.init("agent")]]).validate(kind: .agent))
        XCTAssertThrowsError(try EndpointMetadataLayout(rows: [], rowsByAgent: ["Claude": []]).validate(kind: .agent))
        XCTAssertThrowsError(try EndpointMetadataLayout(rows: [], rowsByAgent: ["codex": []]).validate(kind: .workspace))
    }

    func testDefaultsResolveSnapshotLabelsTitlesAndCustomNamespaces() throws {
        let snapshot = try fixture()
        let values = EndpointMetadataResolver.tokenValues(record: snapshot.agents[0].objectValue!, kind: .agent,
                                                          snapshot: snapshot, machine: "Build Mac")
        XCTAssertEqual(values["machine"], "Build Mac")
        XCTAssertEqual(values["workspace"], "Repo")
        XCTAssertEqual(values["tab"], "Build")
        XCTAssertEqual(values["pane"], "Agent pane")
        XCTAssertEqual(values["agent"], "Codex display")
        XCTAssertEqual(values["state_text"], "Thinking")
        XCTAssertEqual(values["terminal_title"], "⠋ raw title")
        XCTAssertEqual(values["terminal_title_stripped"], "raw title")
        XCTAssertEqual(values["$terminal_title"], "custom title")
        XCTAssertEqual(values["$model"], "agent model")
        let rows = EndpointMetadataResolver.rows(record: snapshot.workspaces[0], kind: .workspace,
                                                 snapshot: snapshot, configuration: .init())
        XCTAssertEqual(rows.map { $0.map { $0.separator + $0.text }.joined() }, ["● Repo", "feature/full-text ↑2 ↓1"])
    }

    func testAbsentTokensEmptyRowsAndSeparators() throws {
        let snapshot = try fixture()
        var configuration = EndpointMetadataConfiguration()
        configuration.spaces.rows = [[.init("$missing")], [], [.init("$missing"), .init("workspace"), .init("branch")]]
        let rows = EndpointMetadataResolver.rows(record: snapshot.workspaces[0], kind: .workspace,
                                                 snapshot: snapshot, configuration: configuration)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].map(\.separator), ["", " · "])
        var record = snapshot.workspaces[0].objectValue!
        record["tokens"] = .array([.array([.string("missing"), .string("")])])
        XCTAssertEqual(EndpointMetadataResolver.rows(record: .object(record), kind: .workspace,
                                                     snapshot: snapshot, configuration: configuration), rows)
    }

    func testOverrideReplacesRowsAndStylesRemainPerOccurrence() throws {
        let snapshot = try fixture()
        var configuration = EndpointMetadataConfiguration()
        configuration.agents.rowsByAgent["codex"] = [[.init("$model", style: .init(bold: true)), .init("$model")]]
        let rows = EndpointMetadataResolver.rows(record: snapshot.agents[0], kind: .agent,
                                                 snapshot: snapshot, configuration: configuration)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].map(\.text), ["agent model", "agent model"])
        XCTAssertEqual(rows[0].map(\.style.bold), [true, nil])
        configuration.agents.rowsByAgent["codex"] = []
        XCTAssertTrue(EndpointMetadataResolver.rows(record: snapshot.agents[0], kind: .agent,
                                                    snapshot: snapshot, configuration: configuration).isEmpty)
    }

    func testRulesMatchCompleteTextBeforeNativeTruncation() throws {
        let snapshot = try fixture()
        var configuration = EndpointMetadataConfiguration()
        configuration.spaces.rows = [[.init("branch", rules: [.init(condition: .equals, value: "feature/full-text", style: .init(bold: true))])]]
        let rows = EndpointMetadataResolver.rows(record: snapshot.workspaces[0], kind: .workspace,
                                                 snapshot: snapshot, configuration: configuration)
        XCTAssertEqual(rows[0][0].text, "feature/full-text")
        XCTAssertEqual(rows[0][0].style.bold, true)
    }

    func testSavedConfigurationRoundTripAndInvalidSaveRejection() throws {
        var configuration = EndpointMetadataConfiguration()
        configuration.agents.rowGap = 2
        configuration.agents.rowsByAgent["claude"] = [[.init("$cost", rules: [.init(condition: .greaterThan, value: "80", style: .init(dim: false))])]]
        XCTAssertEqual(try EndpointMetadataConfiguration.decode(configuration.encoded()), configuration)
        configuration.spaces.rows = [[.init("unknown")]]
        XCTAssertThrowsError(try configuration.encoded())
        XCTAssertThrowsError(try EndpointMetadataConfiguration.decode(#"{"agents":{"rows":[]},"spaces":{"rows":[["unknown"]]}}"#))
    }
}
