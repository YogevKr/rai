import RaiCore
import UIKit
import XCTest
@testable import rai

final class PromptDetectionTests: XCTestCase {
    func testDetectsNumberedPermissionPromptWithoutChangingItsShape() throws {
        let prompt = try XCTUnwrap(PromptDetector.detect(in: Self.permissionGrid))

        XCTAssertEqual(prompt.kind, .numberedPermission)
        XCTAssertEqual(prompt.options.map(\.digit), [1, 2, 3])
        XCTAssertEqual(
            prompt.options.map(\.label),
            [
                "Yes",
                "Yes, and don't ask again",
                "No, and tell Claude what to do differently",
            ]
        )
        XCTAssertEqual(prompt.selectedOptionIndex, 0)
    }

    func testDetectsFirstAskUserQuestionFixture() throws {
        let prompt = try XCTUnwrap(
            PromptDetector.detect(in: try fixture("ask-user-question-q1.txt"))
        )

        XCTAssertEqual(prompt.kind, .askUserQuestion)
        XCTAssertEqual(prompt.currentQuestionIndex, 0)
        XCTAssertEqual(prompt.question, "Which color should the badge use?")
        XCTAssertEqual(prompt.steps.map(\.label), ["Color", "Toppings", "Submit"])
        XCTAssertEqual(prompt.steps.map(\.state), [.current, .pending, .pending])
        XCTAssertEqual(prompt.options.map(\.label), [
            "Red", "Blue", "Green", "Type something.", "Chat about this",
        ])
        XCTAssertEqual(prompt.options.map(\.description), [
            "Use a red badge.", "Use a blue badge.", "Use a green badge.", nil, nil,
        ])
        XCTAssertEqual(prompt.selectedOptionIndex, 0)
        XCTAssertFalse(prompt.multiSelect)
        XCTAssertTrue(prompt.options[3].isFreeText)
        XCTAssertTrue(prompt.options[4].isChat)
        XCTAssertEqual(prompt.submitState, .none)
    }

    func testAskQuestionNumberedTextDoesNotBecomeAnOption() throws {
        let grid = try fixture("ask-user-question-q1.txt").replacingOccurrences(
            of: "Which color should the badge use?",
            with: "1. Check staging before choosing?"
        )

        let prompt = try XCTUnwrap(PromptDetector.detect(in: grid))

        XCTAssertEqual(prompt.question, "1. Check staging before choosing?")
        XCTAssertEqual(prompt.options.map(\.label), [
            "Red", "Blue", "Green", "Type something.", "Chat about this",
        ])
    }

    func testDetectsMultiselectAskUserQuestionFixture() throws {
        let prompt = try XCTUnwrap(
            PromptDetector.detect(in: try fixture("ask-user-question-q2-multiselect.txt"))
        )

        XCTAssertEqual(prompt.kind, .askUserQuestion)
        XCTAssertEqual(prompt.currentQuestionIndex, 1)
        XCTAssertEqual(prompt.question, "Which toppings do you want?")
        XCTAssertEqual(prompt.steps.map(\.state), [.done, .current, .pending])
        XCTAssertEqual(prompt.options.map(\.label), [
            "Cheese", "Olives", "Ham", "Type something", "Chat about this",
        ])
        XCTAssertEqual(prompt.options.map(\.description), [
            "Add cheese.", "Add olives.", "Add ham.", nil, nil,
        ])
        XCTAssertTrue(prompt.multiSelect)
        XCTAssertEqual(prompt.options.prefix(4).map(\.isChecked), [false, false, false, false])
        XCTAssertEqual(prompt.selectedOptionIndex, 0)
        XCTAssertEqual(prompt.submitState, .none)
    }

    func testDetectsAskUserQuestionSubmitFixture() throws {
        let prompt = try XCTUnwrap(
            PromptDetector.detect(in: try fixture("ask-user-question-submit.txt"))
        )

        XCTAssertEqual(prompt.kind, .askUserQuestion)
        XCTAssertNil(prompt.currentQuestionIndex)
        XCTAssertEqual(prompt.question, "Ready to submit your answers?")
        XCTAssertEqual(prompt.submitState, .unavailable)
        XCTAssertEqual(prompt.steps.map(\.state), [.pending, .pending, .current])
        XCTAssertEqual(prompt.options.map(\.label), ["Submit answers", "Cancel"])
        XCTAssertEqual(prompt.options.map(\.description), [nil, nil])
        XCTAssertEqual(prompt.selectedOptionIndex, 0)
        XCTAssertFalse(prompt.multiSelect)
    }

    func testDetectsUnnumberedTrustFixture() throws {
        let prompt = try XCTUnwrap(
            PromptDetector.detect(in: try fixture("trust-dialog.txt"))
        )

        XCTAssertEqual(prompt.kind, .unnumberedConfirm)
        XCTAssertEqual(prompt.options.map(\.digit), [nil, nil])
        XCTAssertEqual(prompt.options.map(\.label), ["No, exit", "Yes, I trust this folder"])
        XCTAssertEqual(prompt.options.map(\.description), [nil, nil])
        XCTAssertEqual(prompt.selectedOptionIndex, 0)
        XCTAssertFalse(prompt.multiSelect)
        XCTAssertEqual(prompt.submitState, .none)
    }

    func testDetectsNumberedAndUnnumberedPlanApprovalShapes() throws {
        let numbered = """
        Would you like to proceed?
        ❯ 1. Yes, and auto-accept edits
          2. Yes, manually approve edits
          3. No, keep planning
        Enter to select · Esc to cancel
        """
        let unnumbered = """
        Would you like to proceed?

        ❯ Yes, and auto-accept edits
          Yes, manually approve edits
          No, keep planning

        Enter to confirm · Esc to cancel
        """

        XCTAssertEqual(PromptDetector.detect(in: numbered)?.kind, .planApproval)
        XCTAssertEqual(PromptDetector.detect(in: unnumbered)?.kind, .planApproval)
        XCTAssertEqual(PromptDetector.detect(in: unnumbered)?.selectedOptionIndex, 0)
        XCTAssertTrue(PromptDetector.detect(in: numbered)?.options[2].isFreeText == true)
        XCTAssertTrue(PromptDetector.detect(in: unnumbered)?.options[2].isFreeText == true)
    }

    func testBeaconProvidesAskUserQuestionLabelsAndDescriptions() throws {
        let grid = try fixture("ask-user-question-q1.txt")
        let beacon = askBeacon(questions: [
            question(
                text: "Which color should the badge use?",
                header: "Color choice",
                options: [
                    ("Red from beacon", "From hook"),
                    ("Blue from beacon", nil),
                    ("Green from beacon", nil),
                ],
                multiSelect: false
            ),
            question(
                text: "Which toppings do you want?",
                header: "Toppings choice",
                options: [("One", nil), ("Two", nil)],
                multiSelect: true
            ),
        ])

        let prompt = try XCTUnwrap(PromptDetector.detect(in: grid, beacon: beacon))

        XCTAssertEqual(prompt.question, "Which color should the badge use?")
        XCTAssertEqual(prompt.steps.map(\.label), ["Color choice", "Toppings choice", "Submit"])
        XCTAssertEqual(prompt.options.prefix(3).map(\.label), [
            "Red from beacon", "Blue from beacon", "Green from beacon",
        ])
        XCTAssertEqual(prompt.options[0].description, "From hook")
        XCTAssertEqual(prompt.options[0].digit, 1)
        XCTAssertTrue(prompt.options[0].isSelected)
    }

    func testBeaconMatchesAWrappedLaterQuestionBeforeMappingLabels() throws {
        let grid = try fixture("ask-user-question-q2-multiselect.txt")
            .replacingOccurrences(
                of: "Which toppings do you want?",
                with: "Which toppings do\nyou want?"
            )
        let beacon = askBeacon(questions: [
            question(
                text: "Which color should the badge use?",
                header: "Color",
                options: [("Red", nil), ("Blue", nil), ("Green", nil)],
                multiSelect: false
            ),
            question(
                text: "Which toppings do you want?",
                header: "Toppings",
                options: [
                    ("Cheese from beacon", nil),
                    ("Olives from beacon", nil),
                    ("Ham from beacon", nil),
                ],
                multiSelect: true
            ),
        ])

        let prompt = try XCTUnwrap(PromptDetector.detect(in: grid, beacon: beacon))

        XCTAssertEqual(prompt.currentQuestionIndex, 1)
        XCTAssertEqual(prompt.question, "Which toppings do you want?")
        XCTAssertEqual(prompt.options.prefix(3).map(\.label), [
            "Cheese from beacon", "Olives from beacon", "Ham from beacon",
        ])
    }

    func testStaleBeaconCannotReplaceGridLabels() throws {
        let grid = try fixture("ask-user-question-q1.txt")
        let staleQuestion = askBeacon(questions: [
            question(
                text: "A prior question?",
                header: "Color",
                options: [("Old Red", nil), ("Old Blue", nil), ("Old Green", nil)],
                multiSelect: false
            ),
            question(
                text: "Another prior question?",
                header: "Toppings",
                options: [("Old One", nil)],
                multiSelect: false
            ),
        ])
        let staleOptions = askBeacon(questions: [
            question(
                text: "Which color should the badge use?",
                header: "Color",
                options: [("Cyan", nil), ("Magenta", nil), ("Yellow", nil)],
                multiSelect: false
            ),
            question(
                text: "Which toppings do you want?",
                header: "Toppings",
                options: [("One", nil)],
                multiSelect: false
            ),
        ])

        XCTAssertEqual(
            PromptDetector.detect(in: grid, beacon: staleQuestion)?.options[0].label,
            "Red"
        )
        XCTAssertEqual(
            PromptDetector.detect(in: grid, beacon: staleOptions)?.options[0].label,
            "Red"
        )
    }

    func testStaleSingleSelectBeaconCannotChangeGridMultiselectState() throws {
        let grid = try fixture("ask-user-question-q2-multiselect.txt")
        let beacon = askBeacon(questions: [
            question(
                text: "Which color should the badge use?",
                header: "Color",
                options: [("Red", nil), ("Blue", nil), ("Green", nil)],
                multiSelect: false
            ),
            question(
                text: "Which toppings do you want?",
                header: "Toppings",
                options: [
                    ("Cheese from beacon", nil),
                    ("Olives from beacon", nil),
                    ("Ham from beacon", nil),
                ],
                multiSelect: false
            ),
        ])

        let prompt = try XCTUnwrap(PromptDetector.detect(in: grid, beacon: beacon))

        XCTAssertEqual(prompt.options[0].label, "Cheese from beacon")
        XCTAssertTrue(prompt.multiSelect)
        XCTAssertEqual(prompt.options.prefix(3).map(\.isChecked), [false, false, false])
    }

    func testBeaconLabelsRequireTheCurrentGridHeader() throws {
        let grid = try fixture("ask-user-question-q2-multiselect.txt")
        let beacon = askBeacon(questions: [
            question(
                text: "Which color should the badge use?",
                header: "Color",
                options: [("Red", nil), ("Blue", nil), ("Green", nil)],
                multiSelect: false
            ),
            question(
                text: "Which toppings do you want?",
                header: "Checks",
                options: [("Cheese from beacon", nil), ("Olives", nil), ("Ham", nil)],
                multiSelect: true
            ),
        ])

        let prompt = try XCTUnwrap(PromptDetector.detect(in: grid, beacon: beacon))

        XCTAssertEqual(prompt.options[0].label, "Cheese")
        XCTAssertEqual(prompt.steps[1].label, "Toppings")
    }

    @MainActor
    func testControllerRefusesSubmitRenderedForAReplacedWizard() throws {
        var liveGrid = try fixture("ask-user-question-submit.txt").replacingOccurrences(
            of: "⚠ You have not answered all questions\n\n",
            with: ""
        )
        let controller = TerminalPromptController()
        controller.readGrid = { liveGrid }
        controller.refresh()
        let rendered = try XCTUnwrap(controller.prompt)
        XCTAssertEqual(rendered.submitState, .ready)

        liveGrid = liveGrid.replacingOccurrences(
            of: "Ready to submit your answers?",
            with: "Ready to submit this replacement?"
        )
        controller.refresh()
        var keys: [String] = []
        controller.submit(renderedPrompt: rendered) { keys.append($0) }

        XCTAssertTrue(keys.isEmpty)
        XCTAssertEqual(controller.prompt?.question, "Ready to submit this replacement?")
    }

    @MainActor
    func testControllerRefusesLegacyOptionAfterPromptReplacement() throws {
        var liveGrid = Self.permissionGrid
        let controller = TerminalPromptController()
        controller.readGrid = { liveGrid }
        controller.refresh()
        let rendered = try XCTUnwrap(controller.prompt)
        let staleOption = rendered.options[1]

        liveGrid = Self.permissionGrid.replacingOccurrences(
            of: "2. Yes, and don't ask again",
            with: "2. No, reject this request"
        )
        controller.refresh()
        var keys: [String] = []
        controller.sendLegacy(renderedPrompt: rendered, option: staleOption) {
            keys.append(String(decoding: $0, as: UTF8.self))
        }

        XCTAssertTrue(keys.isEmpty)
        XCTAssertEqual(controller.prompt?.options[1].label, "No, reject this request")
    }

    @MainActor
    func testControllerRejectsLegacyOptionOutsideRenderedPrompt() throws {
        let controller = TerminalPromptController()
        controller.readGrid = { Self.permissionGrid }
        controller.refresh()
        let rendered = try XCTUnwrap(controller.prompt)
        let invalid = PromptOption(digit: 2, label: "Stale label")
        var keys: [String] = []

        controller.sendLegacy(renderedPrompt: rendered, option: invalid) {
            keys.append(String(decoding: $0, as: UTF8.self))
        }

        XCTAssertTrue(keys.isEmpty)
    }

    @MainActor
    func testControllerRefusesTapAfterBeaconRequestChanges() throws {
        let grid = try fixture("ask-user-question-q1.txt")
        let questions = [
            question(
                text: "Which color should the badge use?",
                header: "Color",
                options: [("Red", nil), ("Blue", nil), ("Green", nil)],
                multiSelect: false
            ),
            question(
                text: "Which toppings do you want?",
                header: "Toppings",
                options: [("Cheese", nil), ("Olives", nil), ("Ham", nil)],
                multiSelect: true
            ),
        ]
        let controller = TerminalPromptController()
        controller.readGrid = { grid }
        controller.beacon = askBeacon(questions: questions, timestamp: 1)
        controller.refresh()
        let rendered = try XCTUnwrap(controller.prompt)

        controller.beacon = askBeacon(questions: questions, timestamp: 2)
        controller.refresh()
        var keys: [String] = []
        controller.select(
            renderedPrompt: rendered,
            option: rendered.options[1],
            through: { keys.append($0) }
        )

        XCTAssertTrue(keys.isEmpty)
    }

    func testQuotedTrustDialogAboveComposerStaysInert() throws {
        XCTAssertNil(
            PromptDetector.detect(in: try fixture("quoted-trust-dialog.txt"))
        )
    }

    func testWrappedUnnumberedLabelCountsAsOneArrowStep() throws {
        let grid = try fixture("trust-dialog-wrapped.txt")
        let prompt = try XCTUnwrap(PromptDetector.detect(in: grid))
        XCTAssertEqual(prompt.options.map(\.label), [
            "No, exit because this folder is not one you trust or created yourself",
            "Yes, I trust this folder",
        ])
        XCTAssertEqual(prompt.selectedOptionIndex, 0)

        var machine = PromptChoreography(
            action: .choose(optionID: prompt.options[1].id),
            prompt: prompt,
            now: 19
        )
        XCTAssertEqual(machine.next(prompt: prompt, now: 19), .sendKey("Down"))

        let movedGrid = grid
            .replacingOccurrences(
                of: " ❯ No, exit because this folder is not one you",
                with: "   No, exit because this folder is not one you"
            )
            .replacingOccurrences(
                of: "   Yes, I trust this folder",
                with: " ❯ Yes, I trust this folder"
            )
        let moved = try XCTUnwrap(PromptDetector.detect(in: movedGrid))
        XCTAssertEqual(machine.next(prompt: moved, now: 20), .sendKey("Enter"))
    }

    @MainActor
    func testIdenticalPromptReappearanceGetsANewInstance() throws {
        var liveGrid = Self.permissionGrid
        let controller = TerminalPromptController()
        controller.readGrid = { liveGrid }
        controller.refresh()
        let first = try XCTUnwrap(controller.prompt)

        liveGrid = "Build complete"
        controller.refresh()
        XCTAssertNil(controller.prompt)
        liveGrid = Self.permissionGrid
        controller.refresh()
        let second = try XCTUnwrap(controller.prompt)
        XCTAssertNotEqual(first.instanceKey, second.instanceKey)

        var keys: [String] = []
        controller.sendLegacy(renderedPrompt: first, option: first.options[0]) {
            keys.append(String(decoding: $0, as: UTF8.self))
        }
        XCTAssertTrue(keys.isEmpty)
    }

    @MainActor
    func testFullFrameInvalidatesAnIdenticalFallbackPrompt() throws {
        let controller = TerminalPromptController()
        controller.readGrid = { Self.permissionGrid }
        controller.refresh()
        let beforeReconnect = try XCTUnwrap(controller.prompt)

        controller.invalidateForFullFrame()
        controller.refresh(frameArrived: true)
        let afterReconnect = try XCTUnwrap(controller.prompt)

        XCTAssertNotEqual(beforeReconnect.instanceKey, afterReconnect.instanceKey)
        var keys: [String] = []
        controller.sendLegacy(
            renderedPrompt: beforeReconnect,
            option: beforeReconnect.options[0]
        ) { keys.append(String(decoding: $0, as: UTF8.self)) }
        XCTAssertTrue(keys.isEmpty)
    }

    func testBeaconRequestIDIsThePromptInstance() throws {
        let beacon = AgentBeacon(
            event: "PermissionRequest",
            sessionID: "session-1",
            cwd: "/repo",
            transcriptPath: "/tmp/session.jsonl",
            toolName: "Bash",
            requestID: "request-42",
            timestamp: 1
        )

        let prompt = try XCTUnwrap(PromptDetector.detect(in: Self.permissionGrid, beacon: beacon))

        XCTAssertEqual(
            prompt.instanceKey,
            .request("request-42", streamGeneration: 0)
        )
        let replacement = AgentBeacon(
            event: "PermissionRequest",
            sessionID: "session-1",
            cwd: "/repo",
            transcriptPath: "/tmp/session.jsonl",
            toolName: "Bash",
            requestID: "request-43",
            timestamp: 1
        )
        XCTAssertFalse(
            PromptDetector.signatureMatches(
                prompt,
                currentGridText: Self.permissionGrid,
                beacon: replacement
            )
        )
    }

    func testTrustDetectionAllowsBlankRowsBelowFooter() throws {
        var rows = try fixture("trust-dialog.txt").split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        if rows.last == "" { rows.removeLast() }
        rows.append(contentsOf: repeatElement("", count: 24 - rows.count))
        let grid = rows.joined(separator: "\n")

        XCTAssertEqual(rows.count, 24)
        XCTAssertEqual(PromptDetector.detect(in: grid)?.kind, .unnumberedConfirm)
    }

    func testQuotedAskUserQuestionAboveComposerStaysInert() throws {
        XCTAssertNil(
            PromptDetector.detect(in: try fixture("quoted-ask-user-question.txt"))
        )
    }

    @MainActor
    func testShellPaneDoesNotExposeClaudeControls() {
        let controller = TerminalPromptController()
        controller.allowsPrompts = ClaudePromptGate.allows(agent: nil, beacon: nil)
        controller.readGrid = { Self.permissionGrid }

        controller.refresh()

        XCTAssertNil(controller.prompt)
        XCTAssertFalse(ClaudePromptGate.allows(agent: "codex", beacon: nil))
    }

    @MainActor
    func testTimedOutCheckboxRetryDoesNotToggleAnAppliedChoiceAgain() throws {
        var clock: TimeInterval = 0
        var liveGrid = try fixture("ask-user-question-q2-multiselect.txt")
        let controller = TerminalPromptController()
        controller.now = { clock }
        controller.readGrid = { liveGrid }
        controller.refresh()
        let rendered = try XCTUnwrap(controller.prompt)
        var keys: [String] = []

        controller.select(
            renderedPrompt: rendered,
            option: rendered.options[0],
            through: { keys.append($0) }
        )
        XCTAssertEqual(keys, ["Space"])

        clock = 5
        controller.refresh()
        XCTAssertFalse(controller.isBusy)
        controller.select(
            renderedPrompt: rendered,
            option: rendered.options[0],
            through: { keys.append($0) }
        )
        XCTAssertEqual(keys, ["Space"])

        liveGrid = liveGrid.replacingOccurrences(of: "[ ] Cheese", with: "[x] Cheese")
        controller.refresh(frameArrived: true)
        controller.select(
            renderedPrompt: rendered,
            option: rendered.options[0],
            through: { keys.append($0) }
        )

        XCTAssertEqual(keys, ["Space"])
        XCTAssertEqual(controller.prompt?.options[0].isChecked, true)
    }

    @MainActor
    func testDismissedIdenticalPromptReappearsAfterAnEmptyFrame() throws {
        var liveGrid = Self.permissionGrid
        let controller = TerminalPromptController()
        controller.readGrid = { liveGrid }
        controller.refresh()
        let first = try XCTUnwrap(controller.prompt)

        controller.dismiss(renderedPrompt: first)
        XCTAssertNil(controller.prompt)
        liveGrid = ""
        controller.refresh()
        liveGrid = Self.permissionGrid
        controller.refresh()

        let second = try XCTUnwrap(controller.prompt)
        XCTAssertNotEqual(first.instanceKey, second.instanceKey)
    }

    func testHeaderMarkerSelectsLaterStepWithoutQuestionTextMatch() throws {
        let grid = try fixture("ask-user-question-q2-multiselect.txt")
            .replacingOccurrences(
                of: "←  ☐ Color  ☐ Toppings  ✔ Submit  →",
                with: "←  ☐ Color  ❯ Checks  ✔ Submit  →"
            )
            .replacingOccurrences(
                of: "Which toppings do you want?",
                with: "Which items do you want?"
            )

        let prompt = try XCTUnwrap(PromptDetector.detect(in: grid))

        XCTAssertEqual(prompt.currentQuestionIndex, 1)
        XCTAssertEqual(prompt.steps.map(\.state), [.done, .current, .pending])
    }

    func testUnknownHooklessStepDisablesNavigation() throws {
        let grid = try fixture("ask-user-question-q2-multiselect.txt")
            .replacingOccurrences(
                of: "Which toppings do you want?",
                with: "Which items do you want?"
            )
        let prompt = try XCTUnwrap(PromptDetector.detect(in: grid))
        XCTAssertNil(prompt.currentQuestionIndex)
        XCTAssertEqual(prompt.steps.map(\.state), [.pending, .pending, .pending])

        var next = PromptChoreography(action: .advance, prompt: prompt, now: 21)
        var previous = PromptChoreography(action: .retreat, prompt: prompt, now: 21)
        XCTAssertEqual(next.next(prompt: prompt, now: 21), .refused)
        XCTAssertEqual(previous.next(prompt: prompt, now: 21), .refused)
    }

    func testSingleChoiceChoreographyVerifiesMarkerThenTabAdvance() throws {
        let firstGrid = try fixture("ask-user-question-q1.txt")
        let first = try XCTUnwrap(PromptDetector.detect(in: firstGrid))
        let target = first.options[1]
        var machine = PromptChoreography(
            action: .choose(optionID: target.id),
            prompt: first,
            now: 10
        )

        XCTAssertEqual(machine.next(prompt: first, now: 10), .sendKey("2"))

        let movedGrid = firstGrid
            .replacingOccurrences(of: "❯ 1. Red", with: "  1. Red")
            .replacingOccurrences(of: "  2. Blue", with: "❯ 2. Blue")
        let moved = try XCTUnwrap(PromptDetector.detect(in: movedGrid))
        XCTAssertFalse(PromptDetector.signatureMatches(first, currentGridText: movedGrid))
        XCTAssertEqual(machine.next(prompt: moved, now: 11), .sendKey("Enter"))

        let next = try XCTUnwrap(
            PromptDetector.detect(in: try fixture("ask-user-question-q2-multiselect.txt"))
        )
        XCTAssertEqual(machine.next(prompt: next, now: 12), .complete)
    }

    func testChoreographyRefusesANewerFrameBeforeItsFirstKey() throws {
        let grid = try fixture("ask-user-question-q1.txt")
        let rendered = try XCTUnwrap(PromptDetector.detect(in: grid))
        var machine = PromptChoreography(
            action: .choose(optionID: rendered.options[1].id),
            prompt: rendered,
            now: 12
        )
        let newerGrid = grid
            .replacingOccurrences(of: "❯ 1. Red", with: "  1. Red")
            .replacingOccurrences(of: "  2. Blue", with: "❯ 2. Blue")
        let newer = try XCTUnwrap(PromptDetector.detect(in: newerGrid))

        XCTAssertEqual(machine.next(prompt: newer, now: 12), .refused)
    }

    func testDigitSelectionRefusesAnUnexpectedQuestionAdvance() throws {
        let first = try XCTUnwrap(
            PromptDetector.detect(in: try fixture("ask-user-question-q1.txt"))
        )
        var machine = PromptChoreography(
            action: .choose(optionID: first.options[1].id),
            prompt: first,
            now: 12
        )
        XCTAssertEqual(machine.next(prompt: first, now: 12), .sendKey("2"))

        let advancedGrid = try fixture("ask-user-question-q2-multiselect.txt")
            .replacingOccurrences(of: "❯ 1. [ ] Cheese", with: "  1. [ ] Cheese")
            .replacingOccurrences(of: "  2. [ ] Olives", with: "❯ 2. [ ] Olives")
        let advanced = try XCTUnwrap(PromptDetector.detect(in: advancedGrid))
        XCTAssertEqual(machine.next(prompt: advanced, now: 13), .refused)
    }

    func testSelectionRefusesAReplacementWithTheSameStepNames() throws {
        let grid = try fixture("ask-user-question-q1.txt")
        let first = try XCTUnwrap(PromptDetector.detect(in: grid))
        var machine = PromptChoreography(
            action: .choose(optionID: first.options[1].id),
            prompt: first,
            now: 14
        )
        XCTAssertEqual(machine.next(prompt: first, now: 14), .sendKey("2"))

        let replacementGrid = grid
            .replacingOccurrences(of: "Which color should the badge use?", with: "Which shade?")
            .replacingOccurrences(of: "Red", with: "Cyan")
            .replacingOccurrences(of: "Blue", with: "Magenta")
            .replacingOccurrences(of: "Green", with: "Yellow")
            .replacingOccurrences(of: "❯ 1. Cyan", with: "  1. Cyan")
            .replacingOccurrences(of: "  2. Magenta", with: "❯ 2. Magenta")
        let replacement = try XCTUnwrap(PromptDetector.detect(in: replacementGrid))
        XCTAssertEqual(machine.next(prompt: replacement, now: 15), .refused)
    }

    func testChoreographyDoesNotAdvanceWhenMarkerDidNotMove() throws {
        let prompt = try XCTUnwrap(PromptDetector.detect(in: try fixture("trust-dialog.txt")))
        var machine = PromptChoreography(
            action: .choose(optionID: prompt.options[1].id),
            prompt: prompt,
            now: 20
        )

        XCTAssertEqual(machine.next(prompt: prompt, now: 20), .sendKey("Down"))
        XCTAssertEqual(machine.next(prompt: prompt, now: 21), .wait)
        XCTAssertEqual(machine.next(prompt: prompt, now: 25), .refused)
    }

    func testUnnumberedChoreographyVerifiesEachArrowBeforeEnter() throws {
        let grid = try fixture("trust-dialog.txt")
        let prompt = try XCTUnwrap(PromptDetector.detect(in: grid))
        var machine = PromptChoreography(
            action: .choose(optionID: prompt.options[1].id),
            prompt: prompt,
            now: 30
        )

        XCTAssertEqual(machine.next(prompt: prompt, now: 30), .sendKey("Down"))

        let moved = try XCTUnwrap(PromptDetector.detect(
            in: grid
                .replacingOccurrences(of: " ❯ No, exit", with: "   No, exit")
                .replacingOccurrences(of: "   Yes, I trust this folder", with: " ❯ Yes, I trust this folder")
        ))
        XCTAssertEqual(machine.next(prompt: moved, now: 31), .sendKey("Enter"))
        XCTAssertEqual(machine.next(prompt: nil, now: 32), .complete)
    }

    func testUnnumberedChoreographyWalksOneVerifiedRowAtATime() throws {
        let firstGrid = """
        Would you like to proceed?

        ❯ First
          Second
          Third

        Enter to confirm · Esc to cancel
        """
        let first = try XCTUnwrap(PromptDetector.detect(in: firstGrid))
        var machine = PromptChoreography(
            action: .choose(optionID: first.options[2].id),
            prompt: first,
            now: 33
        )
        XCTAssertEqual(machine.next(prompt: first, now: 33), .sendKey("Down"))

        let second = try XCTUnwrap(PromptDetector.detect(
            in: firstGrid
                .replacingOccurrences(of: "❯ First", with: "  First")
                .replacingOccurrences(of: "  Second", with: "❯ Second")
        ))
        XCTAssertEqual(machine.next(prompt: second, now: 34), .sendKey("Down"))

        let third = try XCTUnwrap(PromptDetector.detect(
            in: firstGrid
                .replacingOccurrences(of: "❯ First", with: "  First")
                .replacingOccurrences(of: "  Third", with: "❯ Third")
        ))
        XCTAssertEqual(machine.next(prompt: third, now: 35), .sendKey("Enter"))
    }

    func testMultiselectChoreographyVerifiesToggleBeforeAdvance() throws {
        let grid = try fixture("ask-user-question-q2-multiselect.txt")
        let prompt = try XCTUnwrap(PromptDetector.detect(in: grid))
        var toggle = PromptChoreography(
            action: .toggle(optionID: prompt.options[0].id),
            prompt: prompt,
            now: 40
        )

        XCTAssertEqual(toggle.next(prompt: prompt, now: 40), .sendKey("Space"))
        let checked = try XCTUnwrap(PromptDetector.detect(
            in: grid.replacingOccurrences(of: "[ ] Cheese", with: "[x] Cheese")
        ))
        XCTAssertEqual(toggle.next(prompt: checked, now: 41), .complete)

        var advance = PromptChoreography(action: .advance, prompt: checked, now: 42)
        XCTAssertEqual(advance.next(prompt: checked, now: 42), .sendKey("Tab"))
        let submit = try XCTUnwrap(
            PromptDetector.detect(in: try fixture("ask-user-question-submit.txt"))
        )
        XCTAssertEqual(advance.next(prompt: submit, now: 43), .complete)
    }

    func testPreviousQuestionUsesLeftAndVerifiesTheStepChange() throws {
        let second = try XCTUnwrap(
            PromptDetector.detect(in: try fixture("ask-user-question-q2-multiselect.txt"))
        )
        var previous = PromptChoreography(action: .retreat, prompt: second, now: 43)

        XCTAssertEqual(previous.next(prompt: second, now: 43), .sendKey("Left"))

        let first = try XCTUnwrap(
            PromptDetector.detect(in: try fixture("ask-user-question-q1.txt"))
        )
        XCTAssertEqual(previous.next(prompt: first, now: 44), .complete)
    }

    func testLaterSingleSelectQuestionShowsPrevious() throws {
        let grid = try fixture("ask-user-question-q1.txt")
            .replacingOccurrences(
                of: "←  ☐ Color  ☐ Toppings  ✔ Submit  →",
                with: "←  ✔ Color  ❯ Checks  ✔ Submit  →"
            )
        let prompt = try XCTUnwrap(PromptDetector.detect(in: grid))

        XCTAssertFalse(prompt.multiSelect)
        XCTAssertEqual(prompt.currentQuestionIndex, 1)
        XCTAssertTrue(prompt.showsPreviousAction)
    }

    func testFreeTextChoreographyVerifiesEntryModeBeforeCompletion() throws {
        let grid = try fixture("ask-user-question-q1.txt")
        let initial = try XCTUnwrap(PromptDetector.detect(in: grid))
        var machine = PromptChoreography(
            action: .choose(optionID: initial.options[3].id),
            prompt: initial,
            now: 43
        )
        XCTAssertEqual(machine.next(prompt: initial, now: 43), .sendKey("4"))

        let movedGrid = grid
            .replacingOccurrences(of: "❯ 1. Red", with: "  1. Red")
            .replacingOccurrences(of: "  4. Type something.", with: "❯ 4. Type something.")
        let moved = try XCTUnwrap(PromptDetector.detect(in: movedGrid))
        XCTAssertEqual(machine.next(prompt: moved, now: 44), .sendKey("Enter"))
        XCTAssertEqual(machine.next(prompt: moved, now: 45), .wait)

        let editorGrid = movedGrid.replacingOccurrences(
            of: "Enter to select · Tab/Arrow keys to navigate · Esc to cancel",
            with: "Type your answer · Enter to submit · Esc to cancel"
        )
        let editor = try XCTUnwrap(PromptDetector.detect(in: editorGrid))
        XCTAssertEqual(machine.next(prompt: editor, now: 46), .complete)
    }

    func testFreeTextDigitDoesNotSendEnterWhenTheEditorAlreadyOpened() throws {
        let grid = try fixture("ask-user-question-q1.txt")
        let initial = try XCTUnwrap(PromptDetector.detect(in: grid))
        var machine = PromptChoreography(
            action: .choose(optionID: initial.options[3].id),
            prompt: initial,
            now: 46
        )
        XCTAssertEqual(machine.next(prompt: initial, now: 46), .sendKey("4"))

        let editorGrid = grid
            .replacingOccurrences(of: "❯ 1. Red", with: "  1. Red")
            .replacingOccurrences(of: "  4. Type something.", with: "❯ 4. Type something.")
            .replacingOccurrences(
                of: "Enter to select · Tab/Arrow keys to navigate · Esc to cancel",
                with: "Type your answer · Enter to submit · Esc to cancel"
            )
        let editor = try XCTUnwrap(PromptDetector.detect(in: editorGrid))
        XCTAssertTrue(editor.isFreeTextEntryActive)
        XCTAssertEqual(machine.next(prompt: editor, now: 47), .complete)
    }

    func testDuplicateQuestionHeadersHaveUniqueStepIDs() throws {
        let grid = try fixture("ask-user-question-q1.txt").replacingOccurrences(
            of: "←  ☐ Color  ☐ Toppings  ✔ Submit  →",
            with: "←  ☐ Choice  ☐ Choice  ✔ Submit  →"
        )
        let beacon = askBeacon(questions: [
            question(
                text: "Which color should the badge use?",
                header: "Choice",
                options: [("Red", nil), ("Blue", nil), ("Green", nil)],
                multiSelect: false
            ),
            question(
                text: "Which toppings do you want?",
                header: "Choice",
                options: [("Cheese", nil), ("Olives", nil), ("Ham", nil)],
                multiSelect: true
            ),
        ])

        let prompt = try XCTUnwrap(PromptDetector.detect(in: grid, beacon: beacon))

        XCTAssertEqual(Set(prompt.steps.map(\.id)).count, prompt.steps.count)
    }

    func testSubmitNeedsAReadyGridAndUsesItsSelectedRow() throws {
        let unavailableGrid = try fixture("ask-user-question-submit.txt")
        let unavailable = try XCTUnwrap(PromptDetector.detect(in: unavailableGrid))
        var blocked = PromptChoreography(action: .submit, prompt: unavailable, now: 44)
        XCTAssertEqual(blocked.next(prompt: unavailable, now: 44), .refused)

        let readyGrid = unavailableGrid.replacingOccurrences(
            of: "⚠ You have not answered all questions\n\n",
            with: ""
        )
        let ready = try XCTUnwrap(PromptDetector.detect(in: readyGrid))
        XCTAssertEqual(ready.submitState, .ready)
        XCTAssertEqual(ready.steps.map(\.state), [.done, .done, .current])
        var submit = PromptChoreography(action: .submit, prompt: ready, now: 45)
        XCTAssertEqual(submit.next(prompt: ready, now: 45), .sendKey("Enter"))
        XCTAssertEqual(submit.next(prompt: nil, now: 46), .complete)
    }

    func testChoreographyRejectsAReplacementPromptSignature() throws {
        let original = try XCTUnwrap(
            PromptDetector.detect(in: try fixture("ask-user-question-q1.txt"))
        )
        var machine = PromptChoreography(
            action: .choose(optionID: original.options[1].id),
            prompt: original,
            now: 50
        )
        XCTAssertEqual(machine.next(prompt: original, now: 50), .sendKey("2"))

        let replacement = try XCTUnwrap(
            PromptDetector.detect(in: try fixture("trust-dialog.txt"))
        )
        XCTAssertEqual(machine.next(prompt: replacement, now: 51), .refused)
    }

    func testChangedBeaconInvalidatesTheTapSignature() throws {
        let grid = try fixture("ask-user-question-q1.txt")
        let questions = [
            question(
                text: "Which color should the badge use?",
                header: "Color",
                options: [("Red", nil), ("Blue", nil), ("Green", nil)],
                multiSelect: false
            ),
            question(
                text: "Which toppings do you want?",
                header: "Toppings",
                options: [("Cheese", nil), ("Olives", nil), ("Ham", nil)],
                multiSelect: true
            ),
        ]
        let original = try XCTUnwrap(
            PromptDetector.detect(in: grid, beacon: askBeacon(questions: questions, timestamp: 1))
        )

        XCTAssertFalse(
            PromptDetector.signatureMatches(
                original,
                currentGridText: grid,
                beacon: askBeacon(questions: questions, timestamp: 2)
            )
        )
    }

    func testDoesNotDetectOrdinaryNumberedOutput() {
        let grid = """
        Implementation plan:
        1. Add the model
        2. Add the view
        3. Run tests
        """

        XCTAssertNil(PromptDetector.detect(in: grid))
    }

    @MainActor
    func testLiveGridTextReadsCursorAddressedFramesWithoutLinefeeds() {
        let view = GridReadableTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
        view.pinGridSize(cols: 80, rows: 8)
        let frame = "\u{1B}[H\u{1B}[2J"
            + "\u{1B}[1;1HDo you want to proceed?"
            + "\u{1B}[2;1H❯ 1. Yes"
            + "\u{1B}[3;1H  2. No"
            + "\u{1B}[4;1HEsc to cancel · Tab to amend"
        view.feed(byteArray: Array(frame.utf8)[...])

        let grid = view.liveGridText()

        XCTAssertTrue(grid.contains("1. Yes"), "grid was: \(grid)")
        XCTAssertEqual(PromptDetector.detect(in: grid)?.options.map(\.label), ["Yes", "No"])
    }

    func testMovedScreenSignatureDoesNotMatch() throws {
        let prompt = try XCTUnwrap(PromptDetector.detect(in: Self.permissionGrid))

        XCTAssertFalse(
            PromptDetector.signatureMatches(
                prompt,
                currentGridText: "Build completed successfully.\nReady for your next instruction."
            )
        )
    }

    private static let permissionGrid = """
    Claude wants to use Bash
    Do you want to allow this command?
    ❯ 1. Yes
      2. Yes, and don't ask again
      3. No, and tell Claude what to do differently
    Enter to select · Esc to cancel
    """

    private func fixture(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("Tests/Fixtures/claude-dialogs/\(name)"),
            encoding: .utf8
        )
    }

    private func question(
        text: String,
        header: String,
        options: [(String, String?)],
        multiSelect: Bool
    ) -> JSONValue {
        .object([
            "question": .string(text),
            "header": .string(header),
            "options": .array(options.map { label, description in
                var value: [String: JSONValue] = ["label": .string(label)]
                if let description { value["description"] = .string(description) }
                return .object(value)
            }),
            "multiSelect": .bool(multiSelect),
        ])
    }

    private func askBeacon(questions: [JSONValue], timestamp: TimeInterval = 1) -> AgentBeacon {
        AgentBeacon(
            event: "PreToolUse",
            paneID: "pane-1",
            sessionID: "session-1",
            cwd: "/repo",
            transcriptPath: "/tmp/session.jsonl",
            toolName: "AskUserQuestion",
            toolInput: .object(["questions": .array(questions)]),
            timestamp: timestamp
        )
    }
}
