# Native layout controls

## Current status

Both apps passed resize, pane moves, reordering, single closure, and group closure checks.
Candidate43 also confirmed the phone Panes title under Dracula.
No UI cases remain in this document.

## Implementation and earlier evidence

The Mac toolbar and iPhone Actions menu now open Layout.
The sheet captures its workspace, tab, pane, server boot, and owning view.
Focus changes cannot change these targets.

Supported actions:

- Resize a split left, right, up, or down by five percent.
- Move a pane beside a selected pane, into a new tab, or into a new workspace.
- Move a tab before another tab or to the end of its workspace.
- Move a workspace before another workspace or to the end.
- Review and close one workspace or a repository group.

Herdr 0.9 omits `pane.move` from its native endpoint method list.
Rai pins a public API socket before checking a fresh native endpoint boot and captured topology.
The public request uses `focus:false` and never retries.
Rai validates the returned pane identity before selecting it through the owning native endpoint.
Timeouts and ambiguous failures report uncertain completion.
A failed focus request reports that the move completed without selecting the pane.

Reorder requests validate the captured order before converting destination IDs into insertion indexes.
Rai checks the returned order against the requested order.
Herdr does not offer an atomic expected-order condition for tab insertion indexes.
Concurrent clients can still change the order between validation and execution.
Rai reports a mismatched result and does not replay the operation.

Closure reuses `WorkspaceClosePreview`.
The confirmation lists the exact workspace names and warns that closure stops processes.
Rai rejects added group members and changed repository identity.
It closes linked members before the primary workspace.
Each request uses `close_group:false`.
The server rejects primary closure if another client adds a group member during closure.
Partial failures report the number of completed closures.
Unrelated repository groups remain outside the reviewed target set.

## Validation

The copied Mac app compiled with the shared layout sheet and bridge handlers.
The focused test run passed 18 tests with no failures:

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --package-path /private/tmp/rai09-theme-validation-source --jobs 2 \
  --filter 'EndpointLayoutTests|WorkspaceClosePreviewTests|EndpointThemePaletteTests'
```

Log: `/tmp/rai09-layout-final-tests.log`.

Coverage includes captured targets, server restarts, changed topology, insertion boundaries, and server result validation.
Tests also cover group membership, closure order, linked workspace closure, and returned pane identity.
Two palette tests verify imported sidebar contrast without changing the selected appearance mode.

The iOS project registers shared layout tests and `EndpointLayoutBridgeTests`.
The phone tests cover owning view identity, unsupported resize, public pane move, and recoverable results.
Candidate43 passed the combined gates with 876 Mac tests, six skips, 371 iOS tests, and three live SSH tests.
The gates reported zero failures.
The parent agent completed isolated app UI checks on both platforms.

`xcodegen generate --spec ios/project.yml` passed.
`git diff --check` passed.
The latest reviewed branch quality scan reported 157 gating findings and 989 total findings.
Log: `/tmp/rai09-history-final-quality.log`.
The scan includes all agents' changes and does not establish a clean quality gate.
Layout findings include SwiftUI type length and unused-symbol reports for dispatched operations and tests.

## Isolated E2E evidence

Lab: `/private/tmp/rai09-391wxjtr`, session `commands22`.
Evidence: `candidate43-checks.json`, including the recorded Candidate42 Mac layout checks.
Fixture manifest: `layout41-fixtures.json`.

| Action | Mac | iPhone |
| --- | --- | --- |
| Resize | Ratio changed 0.50 → 0.55 → 0.50 | Ratio changed 0.50 → 0.55 → 0.50 |
| Move beside | `w5:p1` moved beside `w5:p3` in `w5:t2` | `w6:p1` moved beside `w6:p3` in `w6:t2` |
| New tab | Created `w5:t3` | Created and selected `w6:t3` |
| Tab order | `w5:t3`, `w5:t1`, `w5:t2` | `w6:t3`, `w6:t1`, `w6:t2` |
| Workspace order | Moved `w5` to the end | Moved `w6` to the end |
| New workspace | Created and selected returned `wA:p1` | Created and selected returned `wD:p1` |
| Single closure | Cancel preserved `wA`; confirmation closed it | Closed `wD` |
| Primary closure | Required group review | Required group review |
| Group closure | Cancel preserved `w7`/`w8`; confirmation closed both | Cancel preserved `wB`/`wC`; confirmation closed both |

Mac closure preserved `w1`, `w2`, `w3`, `w4`, `w6`, `w5`, `wB`, and `wC`.
Later phone closure preserved `w1`, `w2`, `w3`, `w4`, `w5`, and `w6`.
These completed closure fixtures no longer provide live targets for repeated tests.
Prepare new owned fixtures before repeating closure checks.

## Phone title validation

Native navigation bars choose text contrast from the imported sidebar background.
Agent View section headings use the theme's secondary text color on both platforms.
Candidate42 hid the phone Panes large title under Dracula colors.
The Panes sheet now uses an inline title with an explicit theme text color.
Candidate43 confirmed that the title remains readable.
The change preserves the selected appearance mode and explicit metadata colors.

The recorded layout and closure cases have no remaining UI checks in this lane.
