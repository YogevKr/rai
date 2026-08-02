import XCTest
@testable import RaiApp
@testable import RaiCore

final class PaletteItemFieldsTests: XCTestCase {
    func testPathUnderHomeIsSearchableInTildeForm() {
        let item = repoItem(path: "\(NSHomeDirectory())/repos/rai")
        let tilde = item.rankFields.map(\.text).filter { $0.hasPrefix("~/") }
        XCTAssertEqual(tilde, ["~/repos/rai"])
    }

    func testTildeQueryFindsARowByItsPath() {
        // The subtitle shows "~/repos/rai", so that is what people type.
        let item = repoItem(path: "\(NSHomeDirectory())/repos/rai")
        let ranked = PaletteRanking.ranked([item], query: "~/repos/ra", recentIDs: [])
        XCTAssertEqual(ranked.map(\.id), [item.id])
    }

    func testPathOutsideHomeGetsNoTildeField() {
        let item = repoItem(path: "/opt/checkouts/rai")
        XCTAssertEqual(
            item.rankFields.map(\.text).filter { $0.contains("~") },
            []
        )
    }

    private func repoItem(path: String) -> CommandPaletteItem {
        CommandPaletteItem(
            id: "repo:\(path)",
            label: "rai",
            workspaceLabel: RepoDiscoveryPlanner.displayPath(path),
            status: .unknown,
            destination: .newSpace(path: path, label: "rai"),
            kind: .repo,
            matchPath: path
        )
    }
}
