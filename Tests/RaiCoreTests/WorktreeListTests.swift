import RaiCore
import XCTest

final class WorktreeListTests: XCTestCase {
    func testParsesWorktreeListEnvelope() throws {
        let json = """
        {
          "id": "cli-1",
          "result": {
            "type": "worktree_list",
            "source": {
              "repo_key": "/tmp/rai",
              "repo_name": "rai",
              "repo_root": "/tmp/rai",
              "source_checkout_path": "/tmp/rai",
              "source_workspace_id": "w1"
            },
            "worktrees": [
              {
                "path": "/tmp/rai",
                "branch": "main",
                "is_bare": false,
                "is_detached": false,
                "is_prunable": false,
                "is_linked_worktree": false,
                "label": "rai",
                "open_workspace_id": "w1"
              },
              {
                "path": "/tmp/rai-feature",
                "branch": "feat/worktrees",
                "is_bare": false,
                "is_detached": false,
                "is_prunable": false,
                "is_linked_worktree": true,
                "label": "feature"
              }
            ]
          }
        }
        """

        let worktrees = try WorktreeListParser.parse(json)

        XCTAssertEqual(worktrees.count, 2)
        XCTAssertEqual(worktrees[0].branch, "main")
        XCTAssertEqual(worktrees[0].openWorkspaceID, "w1")
        XCTAssertEqual(worktrees[1].path, "/tmp/rai-feature")
        XCTAssertEqual(worktrees[1].branch, "feat/worktrees")
        XCTAssertTrue(worktrees[1].isLinkedWorktree)
        XCTAssertNil(worktrees[1].openWorkspaceID)
    }

    func testParsesDetachedWorktree() throws {
        let json = """
        {
          "id": "cli-2",
          "result": {
            "type": "worktree_list",
            "source": {
              "repo_key": "/tmp/repo",
              "repo_name": "repo",
              "repo_root": "/tmp/repo",
              "source_checkout_path": "/tmp/repo"
            },
            "worktrees": [{
              "path": "/tmp/detached",
              "branch": null,
              "is_bare": false,
              "is_detached": true,
              "is_prunable": false,
              "is_linked_worktree": true,
              "label": "detached",
              "open_workspace_id": null
            }]
          }
        }
        """

        let worktree = try XCTUnwrap(WorktreeListParser.parse(json).first)

        XCTAssertNil(worktree.branch)
        XCTAssertTrue(worktree.isDetached)
    }

    func testRejectsUnexpectedResultType() {
        let json = """
        {"id":"cli-3","result":{"type":"workspace_list","worktrees":[]}}
        """

        XCTAssertThrowsError(try WorktreeListParser.parse(json)) { error in
            XCTAssertEqual(
                error as? WorktreeListParser.ParseError,
                .unexpectedResultType("workspace_list")
            )
        }
    }
}
