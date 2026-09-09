# Herdr 0.9 text validation

Date: 2026-09-09.

## Current status

Both apps passed history search, match navigation, native selection, export, immutable capture, and Reload checks.
Both apps passed exact prompt submission and known-rejection checks. Phone URL activation passed.

Current combined suites: Candidate49, 893 Mac tests and 378 phone tests, zero failures. Seven Mac tests skipped.
Earlier UI results retain their recorded candidate identity.

## Remaining UI cases

Phone ShareLink completed through Save to Files. Mac Share → Copy returned the exact 15,109-character capture.
Both apps passed uncertain prompt delivery, draft retention, disabled resubmission, and no-replay checks on candidate46.
Candidate46 Mac history exposed a shared-tab width mismatch. Candidate48 uses the native final-row endpoint.
Its regression tests and both app retests passed. Different viewport widths retained the same complete final row.
Direct Mac Command-click remains unverified because CUA lacks a held-modifier click operation.
Phone terminal touch dragging remains unverified; the runtime also failed to drag on Simulator Home.
Successful native history selection does not establish terminal touch-drag scrolling.

## Implementation and earlier evidence

Both endpoint views expose History and Search and Agent Prompt actions.
The menus capture the target pane and server identity before opening their sheets.
The iOS project includes the shared sheet and all portable endpoint test files.
`xcodegen generate --spec ios/project.yml` completed after the final source registration check.

## History, selection, and export

History first uses native `pane.copy_motion` with `motion: line_end` for the final column.
It validates the pane, final row, content revision, and column.
History then uses one native `pane.selection.read` request.
The request includes the content revision and absolute row bounds.
A bounded retry refreshes stale content revisions.
The request does not move the pane or change its selection.
One contiguous read preserves wrapped-line behavior.
The capture includes at most 1000 rows and one million UTF-8 bytes.
Wide panes reduce the row limit.
The sheet reports omitted earlier history.
Stale revisions, changed servers, and oversized responses produce errors.

Search and export use the captured text while live output continues.
Search preserves Unicode ranges, counts all matches, and limits navigation to the first 1000 matches.
Export and sharing preserve returned whitespace and Unicode.
Both platforms use native selectable text.
The iOS terminal link handler preserves native selection and accepts captured endpoint plugin links.

Clipboard writes report success only after the platform writer accepts the text.
Failed writes retain selection and copy mode.
Delayed selection clearing checks the copied range and text before clearing.
A later selection remains available.

## Agent prompts

Prompt submission uses one `agent.prompt` request with unchanged multiline text.
The client does not append Enter or retry a failed transport.
A separate writer has a 30-second deadline.
Cancellation closes the writer socket.
Known remote rejection preserves the draft.
Uncertain delivery requires checking the agent before another submission.
The editor pauses during submission to prevent later draft edits from disappearing.

Only documented preflight errors count as definite rejection.
Herdr can report `agent_prompt_failed` or `timeout` after PTY writes begin.
Those errors now require checking the agent before resubmission on both platforms.
Seven shared text tests passed, including error classification and phone result serialization.
Log: `/tmp/rai09-prompt-outcome-tests.log`.

Prompt replies now use a two MiB JSON-line limit before decoding.
The line reader retains its descriptor until the read finishes, preventing descriptor reuse during cancellation.
Herdr has no universal JSON-line response ceiling; its graphics API permits 64 MiB of inline image bytes.
Other public API reads retain their existing size behavior.
This change preserves large legitimate history payloads.
Four transport tests passed, including oversized unterminated prompt replies and a three MiB history reply.
Log: `/tmp/rai09-prompt-response-bound-tests.log`.

The public `agent.prompt` API accepts only `target` and `text`.
It has no expected-server-boot parameter.
Rai checks its captured identity before submission and discards results after connection changes.
This client check cannot provide an atomic server identity condition.

## Validation evidence

Tests used copied production files in `/private/tmp/rai09-theme-validation-source`.
The Mac clipboard run compiled the complete copied RaiApp and RaiCore source trees.
Earlier focused tests used reduced native hosts.

- Mac history and prompt tests: seven passed, zero failures.
- iOS history and link tests: six passed, zero failures.
- Mac clipboard tests: four passed, zero failures.
- Mac text log: `/tmp/rai09-text-native-tests.log`.
- iOS text log: `/tmp/rai09-text-ios-tests.log`.
- Clipboard log: `/tmp/rai09-clipboard-tests.log`.

Prompt transport tests use disposable Unix sockets.
They verify exact Unicode requests, lost responses without replay, and stalled requests without replay.
Clipboard tests verify failed gesture writes, failed keyboard writes, successful writes, and preservation of later selections.

The final clipboard command completed successfully:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --jobs 2 --filter TerminalClipboardTests
```

The latest reviewed branch quality report contains 157 gating findings and 989 total findings.
Log: `/tmp/rai09-history-final-quality.log`.
The report includes all active branch changes.
Focused review found framework callbacks, test discovery, and intentional cross-platform duplication among the reported text findings.
Prompt and explanation requests retain separate writers because their result handling and failure behavior differ.
No clean branch quality result exists.

## Phone history regression

Candidate39 exposed a phone history race after surface revisions changed in transit.
The host compared the phone's history revision with its newer surface and rejected the entire endpoint view.
History now refreshes its range and revision from the owning native endpoint before reading.
The capture keeps its original pane, server boot, and result ID.
The reader retries only `stale_content`, at most three times, with a fresh capture before each attempt.
The server still validates the exact content revision for every selection read.
Other failures return a recoverable result instead of closing the endpoint view.

Ten focused tests passed after this fix.
The bridge regression verifies phone revision 2, host revision 4, a stale response, and successful revision 6.
It then verifies that the same endpoint view accepts another resize.
Log: `/tmp/rai09-phone-history-tests.log`.
The complete copied Mac app compiled during this run.

## Isolated UI evidence

Candidate43 passed 876 Mac tests, six skips, 371 iOS tests, and three live SSH tests without failures.
Evidence lives in `/private/tmp/rai09-391wxjtr`.

`candidate39-checks.json` records Mac history capture with 400 numbered rows and 401 search matches.
Next and Previous selected the expected matches.
Native selection copied an exact row into search.
Export saved 14,935 bytes. Live output left the capture unchanged until Reload.

`candidate42-checks.json` records 401 phone search matches and exact native selection copying of `SCROLL38`.
The integrated validation notes also confirm phone Next and Previous navigation.
Phone export saved 15,023 bytes in `history42-phone.txt`.
Its SHA-256 is `3d9ff1f9cd962fc4ffc9cb7afc37fafa6ab594edd47ced1712ecc0a5c91acb53`.
`candidate43-checks.json` confirms immutable capture, Reload, partial selection, and local export.
Reload included new output without disconnecting the phone endpoint.

Both apps submitted unchanged multiline Unicode prompts once and cleared the editor after success.
Both apps retained `REJECT37` after an `agent_not_ready` rejection.
Phone native taps opened plugin links once per action.
A plain URL opened exactly `https://example.com/rai-lab-unhandled` in Safari without invoking a plugin.
