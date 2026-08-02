import XCTest
@testable import RaiApp
@testable import RaiCore

final class PaletteActionDecisionTests: XCTestCase {
    // MARK: - Modifier mapping

    func testPlainReturnOpens() {
        XCTAssertEqual(PaletteActionDecision.requested(.none), .open)
    }

    func testEachModifierPicksItsAction() {
        XCTAssertEqual(
            PaletteActionDecision.requested(PaletteModifiers(option: true)),
            .newWorktree
        )
        XCTAssertEqual(
            PaletteActionDecision.requested(PaletteModifiers(shift: true)),
            .newTab
        )
        XCTAssertEqual(
            PaletteActionDecision.requested(PaletteModifiers(command: true)),
            .revealInFinder
        )
    }

    func testCombinedModifiersResolveToOneDefinedAction() {
        XCTAssertEqual(
            PaletteActionDecision.requested(
                PaletteModifiers(option: true, shift: true, command: true)
            ),
            .newWorktree
        )
    }

    // MARK: - Support

    func testWorktreeNeedsAPath() {
        XCTAssertTrue(
            PaletteActionDecision.supports(
                .newWorktree, kind: .repo, hasPath: true, isRemote: false
            )
        )
        XCTAssertFalse(
            PaletteActionDecision.supports(
                .newWorktree, kind: .repo, hasPath: false, isRemote: false
            )
        )
    }

    func testNewTabNeedsAPlaceToPutIt() {
        XCTAssertTrue(
            PaletteActionDecision.supports(
                .newTab, kind: .workspace, hasPath: true, isRemote: false
            )
        )
        XCTAssertTrue(
            PaletteActionDecision.supports(
                .newTab, kind: .agent, hasPath: true, isRemote: false
            )
        )
        // A repo has no space yet; a command is not a place.
        XCTAssertFalse(
            PaletteActionDecision.supports(
                .newTab, kind: .repo, hasPath: true, isRemote: false
            )
        )
        XCTAssertFalse(
            PaletteActionDecision.supports(
                .newTab, kind: .command, hasPath: false, isRemote: false
            )
        )
    }

    func testFinderIsLocalOnly() {
        XCTAssertTrue(
            PaletteActionDecision.supports(
                .revealInFinder, kind: .repo, hasPath: true, isRemote: false
            )
        )
        // A remote herd's paths are on the other machine.
        XCTAssertFalse(
            PaletteActionDecision.supports(
                .revealInFinder, kind: .repo, hasPath: true, isRemote: true
            )
        )
    }

    func testOpenIsAlwaysSupported() {
        for kind in [
            CommandPaletteItem.Kind.workspace, .agent, .repo, .command,
        ] {
            XCTAssertTrue(
                PaletteActionDecision.supports(
                    .open, kind: kind, hasPath: false, isRemote: true
                ),
                "\(kind)"
            )
        }
    }

    // MARK: - Resolution

    func testAnUnsupportedModifierFallsBackToOpen() {
        let command = item(kind: .command, path: nil)
        XCTAssertEqual(
            PaletteActionDecision.resolved(
                modifiers: PaletteModifiers(option: true),
                item: command,
                isRemote: false
            ),
            .open
        )
    }

    func testASupportedModifierIsHonoured() {
        let repo = item(kind: .repo, path: "/repos/rai")
        XCTAssertEqual(
            PaletteActionDecision.resolved(
                modifiers: PaletteModifiers(option: true),
                item: repo,
                isRemote: false
            ),
            .newWorktree
        )
    }

    func testAnEmptyPathCountsAsNoPath() {
        let repo = item(kind: .repo, path: "")
        XCTAssertEqual(
            PaletteActionDecision.resolved(
                modifiers: PaletteModifiers(option: true),
                item: repo,
                isRemote: false
            ),
            .open
        )
    }

    // MARK: - Fixture

    private func item(kind: CommandPaletteItem.Kind, path: String?) -> CommandPaletteItem {
        CommandPaletteItem(
            id: "x",
            label: "x",
            workspaceLabel: "x",
            status: .idle,
            destination: .workspace("w1"),
            kind: kind,
            matchPath: path
        )
    }
}
