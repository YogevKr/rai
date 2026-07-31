import XCTest
@testable import RaiCore

final class AgentViewTests: XCTestCase {
    private func record(
        _ paneID: String,
        status: AgentStatus = .idle,
        workspaceID: String? = "w1",
        tabID: String? = "w1:t1",
        agent: String? = "claude",
        seen: Bool = true,
        sequence: UInt64? = nil,
        tokens: [String: String] = [:],
        workspaceOrder: UInt64? = nil,
        tabOrder: UInt64? = nil,
        paneOrder: UInt64? = nil
    ) -> AgentViewRecord {
        AgentViewRecord(
            status: status,
            workspaceID: workspaceID,
            tabID: tabID,
            paneID: paneID,
            agent: agent,
            seen: seen,
            stateChangeSequence: sequence,
            tokens: tokens,
            workspaceOrder: workspaceOrder,
            tabOrder: tabOrder,
            paneOrder: paneOrder
        )
    }

    private func validationMessage(_ spec: AgentViewSetParams) -> String {
        do {
            _ = try AgentViewEvaluator.validate(spec)
            XCTFail("Expected agent-view validation to fail")
            return ""
        } catch let error as AgentViewValidationError {
            return error.message
        } catch {
            XCTFail("Unexpected error: \(error)")
            return ""
        }
    }

    private func nestedFilter(depth: Int) -> AgentViewFilter {
        var filter = AgentViewFilter.exists(.builtin(.agent))
        for _ in 1..<depth {
            filter = .not(filter)
        }
        return filter
    }

    func testWireSpecDecodesHerdrShapeAndRoundTrips() throws {
        let json = """
        {
          "source": "plugin:triage",
          "label": "Needs review",
          "filter": {
            "op": "all",
            "filters": [
              {"op": "eq", "field": "status", "value": "blocked"},
              {"op": "exists", "field": {"token": "ticket"}}
            ]
          },
          "sort": [
            {"field": {"token": "rank"}},
            {"field": "state_change_seq", "order": "desc"}
          ]
        }
        """
        let decoder = JSONDecoder()
        let spec = try decoder.decode(AgentViewSetParams.self, from: Data(json.utf8))

        XCTAssertEqual(spec.source, "plugin:triage")
        XCTAssertEqual(spec.label, "Needs review")
        XCTAssertEqual(
            spec.sort,
            [
                AgentViewSort(field: .token("rank")),
                AgentViewSort(
                    field: .builtin(.stateChangeSequence),
                    order: .descending
                ),
            ]
        )
        XCTAssertEqual(
            try decoder.decode(
                AgentViewSetParams.self,
                from: JSONEncoder().encode(spec)
            ),
            spec
        )
    }

    func testWireDefaultsRejectExplicitNull() {
        let decoder = JSONDecoder()

        XCTAssertThrowsError(
            try decoder.decode(
                AgentViewSetParams.self,
                from: Data(#"{"source":"test","sort":null}"#.utf8)
            )
        )
        XCTAssertThrowsError(
            try decoder.decode(
                AgentViewSetParams.self,
                from: Data(
                    #"{"source":"test","sort":[{"field":"attention","order":null}]}"#.utf8
                )
            )
        )
    }

    func testNestedFilterTreeMatchesHerdrSemantics() throws {
        let spec = AgentViewSetParams(
            source: "test",
            filter: .all([
                .oneOf(
                    field: .builtin(.status),
                    values: [.string("working"), .string("blocked")]
                ),
                .any([
                    .equal(field: .builtin(.agent), value: .string("codex")),
                    .exists(.token("urgent")),
                ]),
                .not(
                    .equal(
                        field: .builtin(.workspaceID),
                        value: .string("excluded")
                    )
                ),
            ])
        )
        let records = [
            record(
                "keep",
                status: .working,
                agent: "claude",
                tokens: ["urgent": "yes"]
            ),
            record("wrong-status", status: .idle, agent: "codex"),
            record("wrong-agent", status: .blocked, agent: "claude"),
            record(
                "excluded",
                status: .working,
                workspaceID: "excluded",
                agent: "codex"
            ),
        ]

        XCTAssertEqual(
            try AgentViewEvaluator.apply(spec, to: records).compactMap(\.paneID),
            ["keep"]
        )
    }

    func testContextValuesTrackCurrentWorkspaceAndTab() throws {
        let spec = AgentViewSetParams(
            source: "test",
            filter: .all([
                .equal(
                    field: .builtin(.workspaceID),
                    value: .context(.currentWorkspaceID)
                ),
                .equal(
                    field: .builtin(.tabID),
                    value: .context(.currentTabID)
                ),
            ])
        )
        let records = [
            record("first", workspaceID: "w1", tabID: "w1:t1"),
            record("second", workspaceID: "w2", tabID: "w2:t3"),
        ]

        let result = try AgentViewEvaluator.apply(
            spec,
            to: records,
            context: AgentViewEvaluationContext(
                currentWorkspaceID: "w2",
                currentTabID: "w2:t3"
            )
        )
        XCTAssertEqual(result.compactMap(\.paneID), ["second"])
    }

    func testStringFiltersUseRustByteEquality() throws {
        let composed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        XCTAssertEqual(composed, decomposed)

        let spec = AgentViewSetParams(
            source: "test",
            filter: .equal(
                field: .builtin(.agent),
                value: .string(composed)
            )
        )
        let records = [
            record("decomposed", agent: decomposed),
            record("composed", agent: composed),
        ]

        XCTAssertEqual(
            try AgentViewEvaluator.apply(spec, to: records).compactMap(\.paneID),
            ["composed"]
        )
    }

    func testMultiFieldSortIsStableAndKeepsMissingValuesLast() throws {
        let spec = AgentViewSetParams(
            source: "test",
            sort: [
                AgentViewSort(field: .token("rank")),
                AgentViewSort(
                    field: .builtin(.stateChangeSequence),
                    order: .descending
                ),
            ]
        )
        let records = [
            record("stable-a", sequence: 3, tokens: ["rank": "a"]),
            record("missing", sequence: 100),
            record("later", sequence: 9, tokens: ["rank": "a"]),
            record("stable-b", sequence: 3, tokens: ["rank": "a"]),
            record("last-rank", sequence: 20, tokens: ["rank": "z"]),
        ]

        XCTAssertEqual(
            try AgentViewEvaluator.apply(spec, to: records).compactMap(\.paneID),
            ["later", "stable-a", "stable-b", "last-rank", "missing"]
        )
    }

    func testEmptyCustomSortUsesSelectedBuiltInSort() throws {
        let spec = AgentViewSetParams(source: "test")
        let records = [
            record("old-working", status: .working, sequence: 2),
            record("done", status: .done, seen: false, sequence: 1),
            record("new-working", status: .working, sequence: 8),
        ]

        XCTAssertEqual(
            try AgentViewEvaluator.apply(
                spec,
                to: records,
                fallbackSort: .grouped
            ).compactMap(\.paneID),
            ["old-working", "done", "new-working"]
        )
        XCTAssertEqual(
            try AgentViewEvaluator.apply(
                spec,
                to: records,
                fallbackSort: .priority
            ).compactMap(\.paneID),
            ["done", "new-working", "old-working"]
        )
    }

    func testValidationNormalizesSourceAndLabel() throws {
        let spec = try AgentViewEvaluator.validate(
            AgentViewSetParams(
                source: "  plugin:triage  ",
                label: "  Needs\u{0007} review  "
            )
        )

        XCTAssertEqual(spec.source, "plugin:triage")
        XCTAssertEqual(spec.label, "Needs review")
        XCTAssertEqual(AgentViewSetParams(source: "test").displayLabel, "filtered")

        let joinedEmoji = "👩‍💻"
        XCTAssertEqual(
            try AgentViewEvaluator.validate(
                AgentViewSetParams(source: "test", label: joinedEmoji)
            ).label,
            joinedEmoji
        )
    }

    func testValidationEnforcesDepthNodeValueAndSortLimits() throws {
        let leaf = AgentViewFilter.exists(.builtin(.agent))

        XCTAssertNoThrow(
            try AgentViewEvaluator.validate(
                AgentViewSetParams(
                    source: "test",
                    filter: nestedFilter(depth: AgentViewEvaluator.maximumFilterDepth)
                )
            )
        )
        XCTAssertTrue(
            validationMessage(
                AgentViewSetParams(
                    source: "test",
                    filter: nestedFilter(
                        depth: AgentViewEvaluator.maximumFilterDepth + 1
                    )
                )
            ).contains("nested at most 8 levels")
        )

        XCTAssertNoThrow(
            try AgentViewEvaluator.validate(
                AgentViewSetParams(
                    source: "test",
                    filter: .all(
                        Array(
                            repeating: leaf,
                            count: AgentViewEvaluator.maximumFilterNodes - 1
                        )
                    )
                )
            )
        )
        XCTAssertTrue(
            validationMessage(
                AgentViewSetParams(
                    source: "test",
                    filter: .all(
                        Array(
                            repeating: leaf,
                            count: AgentViewEvaluator.maximumFilterNodes
                        )
                    )
                )
            ).contains("at most 64 nodes")
        )

        let validValues = Array(
            repeating: AgentViewValue.string("idle"),
            count: AgentViewEvaluator.maximumFilterValues
        )
        XCTAssertNoThrow(
            try AgentViewEvaluator.validate(
                AgentViewSetParams(
                    source: "test",
                    filter: .oneOf(
                        field: .builtin(.status),
                        values: validValues
                    )
                )
            )
        )
        XCTAssertTrue(
            validationMessage(
                AgentViewSetParams(
                    source: "test",
                    filter: .oneOf(
                        field: .builtin(.status),
                        values: validValues + [.string("idle")]
                    )
                )
            ).contains("1 to 32 values")
        )

        let validSorts = Array(
            repeating: AgentViewSort(field: .builtin(.attention)),
            count: AgentViewEvaluator.maximumSortFields
        )
        XCTAssertNoThrow(
            try AgentViewEvaluator.validate(
                AgentViewSetParams(source: "test", sort: validSorts)
            )
        )
        XCTAssertTrue(
            validationMessage(
                AgentViewSetParams(
                    source: "test",
                    sort: validSorts + [
                        AgentViewSort(field: .builtin(.workspaceOrder)),
                    ]
                )
            ).contains("at most 8 fields")
        )
    }

    func testValidationRejectsEmptySetsAndInvalidFieldValues() {
        XCTAssertTrue(
            validationMessage(
                AgentViewSetParams(source: "test", filter: .all([]))
            ).contains("must not be empty")
        )
        XCTAssertTrue(
            validationMessage(
                AgentViewSetParams(
                    source: "test",
                    filter: .oneOf(field: .builtin(.status), values: [])
                )
            ).contains("1 to 32 values")
        )
        XCTAssertTrue(
            validationMessage(
                AgentViewSetParams(
                    source: "test",
                    filter: .equal(
                        field: .builtin(.status),
                        value: .context(.currentWorkspaceID)
                    )
                )
            ).contains("context type")
        )
        XCTAssertTrue(
            validationMessage(
                AgentViewSetParams(
                    source: "test",
                    filter: .equal(
                        field: .builtin(.status),
                        value: .string("waiting")
                    )
                )
            ).contains("unknown agent status")
        )
        XCTAssertTrue(
            validationMessage(
                AgentViewSetParams(
                    source: "test",
                    filter: .equal(
                        field: .builtin(.seen),
                        value: .string("true")
                    )
                )
            ).contains("value type")
        )
        XCTAssertTrue(
            validationMessage(
                AgentViewSetParams(
                    source: "test",
                    filter: .exists(.token("not valid"))
                )
            ).contains("invalid agent view token")
        )
    }

    func testValidationEnforcesSourceAndLabelLimits() {
        XCTAssertTrue(
            validationMessage(
                AgentViewSetParams(source: String(repeating: "a", count: 121))
            ).contains("at most 120 characters")
        )
        XCTAssertTrue(
            validationMessage(
                AgentViewSetParams(source: "not valid")
            ).contains("contain only ASCII")
        )
        XCTAssertTrue(
            validationMessage(
                AgentViewSetParams(
                    source: "test",
                    label: String(repeating: "a", count: 33)
                )
            ).contains("at most 32 characters")
        )
    }
}
