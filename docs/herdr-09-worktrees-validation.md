# Herdr 0.9 worktree and administration validation

Date: 2026-09-09.

## Current status

Both apps passed creation and opening checks.
Both apps passed removal cancellation, dirty rejection, and confirmed force removal.
Candidate43 fixed and verified Mac creation navigation.
Both apps passed trust clearing after target changes and dismissal.
Both apps passed isolated server-stop cancellation and confirmation.

Current combined evidence: Candidate43, zero test failures.

## Remaining UI cases

Verify unrelated views retain their selection during opening and background removal.

## Implementation and earlier evidence

Both endpoint views expose a shared Worktrees sheet.
Actions include list, create, open, and remove.
The sheet captures the server boot identity and workspace target.
The model rejects requests after server replacement or workspace removal.
The phone bridge retains the client view identity and request sequence.

Creation and opening use `focus: true` through the native endpoint.
Herdr applies this navigation to the owning client view.
This follows `src/server/headless/client_views.rs` and `endpoint_requests.rs`.
The public API uses different focus behavior.
Existing Mac CLI worktree creation keeps `--no-focus` and selects the result locally.

An isolated Mac UI check found lost navigation after successful deferred creation.
The handler now selects the returned pane through a fresh request on the same endpoint.
The request keeps the captured server boot identity.
Navigation failure reports that the worktree action completed and the view could not select it.
Seven focused worktree tests passed after this change.
Log: `/tmp/rai09-worktree-navigation-tests.log`.
Candidate43 confirmed Mac creation navigation after this fix.
Candidate39 confirmed that Mac opening selects the returned pane.

Worktree removal requires an explicit target confirmation.
The sheet offers force removal separately and describes file deletion.
Main checkouts cannot use the removal action.
Unopened worktrees must open before removal because Herdr requires a workspace ID.
Background removal in the Mac main window now refreshes with selection preservation.

Repository trust applies to one submitted action.
The sheet clears the trust choice after submission and workspace changes.
No trust preference is stored.
Worktree errors remain inside the sheet and do not stop terminal input.
Requests have no replay path.

The phone now offers explicit server stop through its existing management sheet.
The host advertises the separate `herdr_server_stop` capability only for local sessions.
Old hosts cannot receive the new stop action.
The confirmation names the Mac and session and describes the loss of running commands.
The host checks the captured identity and captures the socket before starting the stop command.
Disconnect and detach paths do not stop servers.

Focused validation uses copied production source outside the active worktree.
A reduced native test host excludes unfinished parallel changes.

- Mac: eight tests passed, zero failures.
- iOS: ten tests passed, zero failures.
- Log: `/tmp/rai09-worktree-native-tests.log`.
- Phone validation log: `/tmp/rai09-worktree-ios-tests.log`.
- Snapshot: `/private/tmp/rai09-theme-validation-source`.
- Simulator: `5990A3A3-B6DA-4B1C-B715-899C0E4F5AD8`.

Tests cover explicit navigation, captured targets, one-action trust, malformed paths, removal constraints, and bridge identity.
Management tests cover capability negotiation and confirmed-request serialization.
Phone tests cover unsupported actions, stale requests, closed views, and recoverable worktree errors.

## Isolated UI evidence

Candidate43 passed 876 Mac tests, six skips, 371 iOS tests, and three live SSH tests without failures.
Evidence lives in `/private/tmp/rai09-391wxjtr`.

The integrated validation notes record worktree creation through both native sheets.
Both submissions cleared the one-action trust switch.
Phone creation selected its new workspace and preserved Mac selection.
Mac creation preserved phone selection, but initially failed to select its returned pane.
Candidate43 retested creation and selected the returned pane `wE:p1`.
The window title changed to Mac Navigation43.
Independent inventory confirmed the label, returned pane, and exact `text43-mac-navigation` checkout.
Evidence: `mac43-worktree-created-workspaces.json` and `mac43-worktree-created-pane.json`.

`candidate39-checks.json` confirms Mac opening selects the returned pane.
Removal cancellation preserved the checkout.
Normal removal rejected untracked data and preserved its contents.
Force removal displayed the data-loss notice and removed only the owned checkout and workspace.

The Candidate43 phone opened `text37-phone` from `w2` and selected the returned pane `w4:p1`.
The parent confirmed the Worktree opened result and Panes selection.
Public inventory also confirmed `w4:p1` after opening.
This inventory does not prove the separate SSH Mac view selection.
Phone removal cancellation preserved the listed checkout.
Normal removal returned `dirty_worktree_requires_force` for the exact phone checkout.
Independent inspection confirmed the original marker contents, checkout, and `w4` survived.
The inventory still contained `w1`, `w2`, `w3`, `w4`, `w5`, and `w6`.
Evidence: `phone43-worktree-dirty-rejection.json`.

The phone enabled Force and confirmed the warning for the exact `text37-phone` checkout.
The UI reported Worktree removed.
Independent inspection confirmed the checkout, marker, and `w4` no longer existed.
Workspaces `w1`, `w2`, `w3`, `w5`, and `w6` remained.
The primary `text37-main` and linked `text37-mac` checkouts remained.
Evidence: `phone43-worktree-force-removal.json`.


## Completed phone removal fixture

The removed checkout was `/private/tmp/rai09-391wxjtr/repos/text37-phone` on branch `ui-phone37`.
Workspace `w4` was Phone Worktree37; its pane was `w4:p1`.
Fixture preparation added only `rai-phone43-owned-untracked.txt` and did not change focus.
The phone UI then completed cancellation, dirty rejection, and confirmed force removal.
Do not reuse the removed workspace or checkout as a live target.

Captured state lives in the lab root:

- `phone43-worktree-workspace-before.json`
- `phone43-worktree-phone_panes-before.json`
- `phone43-worktree-dirty-rejection.json`
- `phone43-worktree-force-removal.json`

## Completed Mac creation navigation fixture

Use local session `commands22`, workspace `w2`, and repository `/private/tmp/rai09-391wxjtr/repos/text37-main`.
The same workspace ID on SSH Lab One identifies a different target.
Read-only inspection confirmed the local repository was clean on `main`.
The branch and checkout path did not exist before the UI test.

| Field | Value |
| --- | --- |
| Branch | `ui-mac43-navigation` |
| Path | `/private/tmp/rai09-391wxjtr/repos/text43-mac-navigation` |
| Label | Mac Navigation43 |

The Mac Worktrees sheet created this checkout and selected the returned pane `wE:p1`.
Earlier creation checks confirmed one-action trust clearing and independent phone selection.
The later Mac navigation retest verified the returned pane; it did not record a new phone selection comparison.
Initial fixture inspection did not create a branch, checkout, or workspace.
The subsequent UI test created all three.

## Completed trust and server-stop checks

Mac Candidate43 and phone Candidate44 cleared trust after changing the worktree target.
Both apps also cleared unused trust after dismissal and reopening.
These checks submitted no worktree action.
Evidence: `theme43-trust-stop-checks.json` in the lab root.

Two empty named servers provided stop fixtures: `stop43-mac` and `stop43-phone`.
Their initial inventories and exact sockets appear in `stop43-fixtures.json`.
Selecting each session in Rai created only a disposable default shell pane.
Mac settings displayed the exact `stop43-mac` socket before the stop action.
The phone target and confirmation both named `stop43-phone` and localhost.

Cancel preserved each server and its workspace inventory.
Confirmation stopped each server and removed its socket.
Mac displayed Herdr server stopped. Phone displayed Stopped Herdr server: stop43-phone.
Independent reads confirmed `commands22` and `graphics36-stable` remained available after both stops.
The parent session returned to `commands22` after the checks.

Evidence files in the lab root:

- `stop43-mac-after-cancel.json`
- `stop43-mac-after-confirm.json`
- `stop43-phone-after-cancel.json`
- `stop43-phone-after-confirm.json`

The latest reviewed branch quality report contains 157 gating findings and 989 total findings.
Log: `/tmp/rai09-history-final-quality.log`.
The report includes all agents' changes and does not establish a clean quality gate.
