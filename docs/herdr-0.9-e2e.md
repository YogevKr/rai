# Herdr 0.9 isolated app end-to-end tests

Date: 2026-09-09.

Status: Several isolated scenarios passed on both platforms. The full feature matrix remains incomplete.
Yogev excluded Muse-specific work on 2026-09-08. Real Muse setup and E08 are no longer release requirements.
Current iOS verification uses the isolated simulator. Physical-device behavior remains unverified and does not stop implementation.

## Current verification checkpoint

The [integrated validation checkpoint](herdr-09-integrated-validation.md) records the latest combined candidate and UI checks.
The sections below preserve earlier checks. Their remaining-work statements describe those earlier builds.

### Appearance, borders, and recovery checkpoint

Both native views passed Light, Dark, and System selection in the isolated apps.
The phone followed live simulator appearance changes. The Mac returned to its current system mode after explicit modes.
SwiftUI retained explicit appearance when System supplied no preference. The views now resolve System from their owning platform.
The phone monitor scopes its dark environment to its content, so sheets can use device appearance.
Mac and phone retained different choices. Always, Auto, and Off passed one-pane and two-pane checks.
Border changes preserved pane reads and terminal positions. The Mac built-in scroll track remained absent after resize.
Evidence: `/private/tmp/rai09-391wxjtr/appearance29-checks.json`.
Separate Mac windows passed Light with Always borders and Dark with borders off.
New windows use the last saved choices. The app does not automatically reopen extra windows after restart.
Evidence: `/private/tmp/rai09-391wxjtr/window34-checks.json` and `/private/tmp/rai09-391wxjtr/window35-checks.json`.
Live Mac system changes, theme import, and palette overrides remain incomplete.

The phone recovered automatically after an isolated Mac restart and after app suspension.
Return reached only the selected test pane after each recovery. The other pane remained unchanged.
Recovery used new view identities. A closed Workspace View stayed closed after another host restart.
Regression tests cover dropped queued commands, duplicate snapshots, closed views, and unsupported hosts.
Evidence: `/private/tmp/rai09-391wxjtr/recovery31-checks.json`.
Focused checks passed 11 Mac tests and 13 iOS tests, with zero failures.
Logs: `/tmp/rai09-appearance31-mac-tests.log` and `/tmp/rai09-recovery31-ios-tests.log`.
The full gates then passed 741 Mac tests, with two skipped, and 269 iOS tests. Both reported zero failures.
Logs: `/tmp/rai09-recovery32-mac-tests.log` and `/tmp/rai09-recovery32-ios-tests.log`.
Color-helper checks then passed 10 Mac tests and 15 iOS tests. The scene-appearance regression test also passed.
Logs: `/tmp/rai09-appearance33-mac-tests.log`, `/tmp/rai09-appearance33-ios-tests.log`, and `/tmp/rai09-window34-mac-tests.log`.
The temporary pane `w1:p3` on `commands22` was closed. The original six lab panes remain separate.

### Native popup checkpoint

Both native views render the popup terminal, title, cursor, links, and translated image placements.
The popup hides pane content while active. Popup input carries its terminal identity through the bridge and endpoint transport.
The transport rejects pane input during a popup. It also rejects input for replaced or closed popups.
Both isolated apps recovered popup text after restart. Phone and Mac Return closed the popup without changing pane text.
Popup images passed Mac rendering, phone rendering, phone rotation, and removal after closure.
Evidence: `/private/tmp/rai09-391wxjtr/popup23-checks.json` and `/private/tmp/rai09-391wxjtr/popup24-checks.json`.
The latest full gates passed 736 Mac tests, with two skipped, and 262 iOS tests. Both reported zero failures.
After the image fix, nine focused tests passed on each platform.
Logs: `/tmp/rai09-popup23-mac-tests.log`, `/tmp/rai09-popup23-ios-tests.log`, `/tmp/rai09-popup24-focused.log`, `/tmp/rai09-popup24-ios-tests.log`.
The quality gate reports 105 branch findings. Codex review remains unavailable until its September 15 usage reset.
Popup mouse reporting, plugin selection actions, popup links, and repeated image replacement remain unverified.

### Native commands and news checkpoint

Both native endpoint views expose captured command lists and Herdr news.
Commands retain the selected workspace, tab, and pane. The host validates command and resource ownership before invocation.
Both isolated apps invoked a lab command with the expected pane, tab, workspace, and working directory.
Both apps displayed release-note text, version, and Unicode content.
Both apps rejected a command removed during an open command list. The invocation count remained unchanged.
Evidence: `/private/tmp/rai09-391wxjtr/commands22-checks.json`.
Mac tests passed 733 tests, with two skipped. iOS tests passed 260 tests. Both reported zero failures.
Logs: `/tmp/rai09-commands22-mac-tests.log` and `/tmp/rai09-commands22-ios-tests.log`.
One phone connection failed automatic reconnect. An app restart restored the connection. Its cause remains unverified.
The separate `commands22` server remains available for popup checks. The original six lab panes remain running.

### Mac Unicode checkpoint

Native Mac input normalizes attributed text and preserves printable Unicode key events outside active composition.
The focused input tests passed. Unicode paste passed through the isolated UI and `pane.read`.
Direct CUA Unicode typing produced altered text. Direct Unicode typing remains unverified.
CUA also omitted Unicode in a native SwiftUI search field. The failure reproduces outside the terminal renderer.
Evidence: `/private/tmp/rai09-391wxjtr/input21-checks.json`.
The image fixture tab and pane were removed. The six original lab panes remained present.

### Native image checkpoint

Both native endpoint views render validated RGB, RGBA, and PNG images through SwiftTerm.
The connection resolves retained assets before it combines surface updates.
The phone bridge sends changed image bytes. The phone retains data across later image-free updates.
Images remain within grid bounds. The cache limits encoded bytes to 8 MiB and decoded pixels to four megapixels.
Placement rendering uses the same pixel limit. An oversized image does not suppress smaller neighboring images.
Mac Images and phone Inspect Images open a captured image inspection sheet.

Both isolated apps passed two-image placement, inspection, replacement, restart, history recovery, partial clipping, rotation, and deletion checks.
A captured phone inspection remained unchanged while the Mac received an image replacement.
SwiftTerm freed unused neighboring images during replacement. The encoder now reloads the bounded scene when it retires an asset.
A shared regression test exercises that renderer behavior on macOS and iOS.
The Mac suite passed 728 tests, with two skipped. The iOS suite passed 257 tests. Both reported zero failures.
Evidence: `/private/tmp/rai09-391wxjtr/images19-checks.json`.
Logs: `/tmp/rai09-images19-mac-tests.log` and `/tmp/rai09-images19-ios-tests.log`.
The quality gate still reports 107 earlier failing findings across the branch.
Graphics configuration aliases, alpha and z-order combinations, popup graphics, and direct uploads remain unverified.


### Native history checkpoint

Both native endpoint views expose History Page Up, History Page Down, and Return to Live Output.
Mac wheel input sends bounded absolute history offsets. Phone requests retain only the latest pending offset.
Renderers hide server scrollbar cells without changing terminal dimensions.
A five-point overlay uses 0.65 opacity and hides after 700 milliseconds without scroll activity.

Isolated Mac wheel input, page-up, live-output recovery, overlay display, and overlay expiry passed.
The phone passed page-up, page-down, live-output recovery, overlay display, overlay expiry, rotation, and subsequent command input.
Phone app restart reopened the Workspace View. Fixture closure reached both views.
The test removed only `w9:t4` and `w9:p6`. All six original panes remain.
Herdr owns history position per pane. Views of the same pane share that history position.
Phone touch scrolling remains unverified: CUA drag produced no recognizer events and could not scroll the standard phone list.
A regression test verifies gesture origin ownership and rejection during text selection or horizontal movement.
Evidence: `/private/tmp/rai09-391wxjtr/scroll15-checks.json`.
The focused phone gate passed nine tests. The subsequent full phone gate passed 251 tests with zero failures.


### Phone workspace and text interaction checkpoint

The phone Workspace View uses its own native endpoint through the authenticated Mac bridge.
The existing phone observation view remains available.
Both phone views expose Select Text, Copy, Share, and ordinary web-link taps.
Capturing text keeps selection stable while output continues. Remote Mac file paths remain remote.
The semantic renderer preserves zero-based OSC 8 targets and repaints changed hyperlink tables.
Control bytes cannot enter generated OSC 8 targets.

The isolated simulator opened a workspace and created test tab `w9:t3` with pane `w9:p4`.
It entered commands, rendered output, selected another pane, and reconnected after opening Safari.
Mac window 1 retained `w1:p3` while the phone selected `w9:p4` and opened links.
Direct web-link taps opened Safari from both phone terminal paths.
An explicit `PHONE_LINK` label opened `https://example.org` from the phone Workspace View.
Copy returned `SELECTION` from the workspace capture and `STABLE` from the observation capture.
The latter capture stopped at `OUTPUT_10`; the owned shell continued through `OUTPUT_20`.
The selected word and captured text stayed unchanged after output completed.
Rotation exposed retained local screen rows. Endpoint renderers now disable local scrollback because Herdr owns history.

The corrected build rendered split panes without retained local rows in portrait and landscape.
Final reconnect input reached only `w9:p5`. Pane closure removed only that temporary split.
Tab closure then removed `w9:p4`. Every original pane remained.
Evidence: `/private/tmp/rai09-391wxjtr/phone12-checks.json` and its referenced stage records.
Final Mac SHA-256: `e221e72f0831e56debc0d3b7d08e7fed92029e43b53ab36501213ca1f7b0972c`.
The final gates passed 719 Mac tests, with two skipped, and 249 iOS tests.
Logs: `/tmp/rai09-phone12-mac.log` and `/tmp/rai09-phone12-ios.log`.

Phone tests cover matching rendered input, failed writes, queue limits, stale identity, and closure races.
Mac tests cover bridge rejection, audit content, safe link encoding, and the live isolated endpoint.
The Codex review still reports its usage limit. No clean final review exists for this slice.
Review log: `/tmp/rai09-phone8-review.log`.
The quality gate reports 107 findings across the uncommitted branch. It does not pass.
Quality log: `/tmp/rai09-phone12-quality.txt`.

The newer history checkpoint above adds endpoint history controls and activity-only overlays.
Graphics, popups, semantic mouse input, plugin links, and full history coverage remain incomplete.
This checkpoint does not complete the release matrix or every independent-view scenario.

### Native Mac endpoint checkpoint

Generation-one transport drives additional Mac windows. The primary window retains its previous terminal path.
The phone checkpoint above adds a separate Workspace View.
Full surfaces and incremental patches render through SwiftTerm. Each window owns its connection, selection, and input queue.
Mac menus now route tab creation, tab selection, pane splitting, pane focus, zoom, and workspace actions through that connection.
Some independent window commands remain missing, including agent launch, tab restoration, and command search.
Graphics, popup rendering, and semantic mouse input remain incomplete.
The phone checkpoint above adds semantic hyperlinks and ordinary phone link handling.

The isolated Mac created tab `w9:t2`, then split its terminal into `w9:p2` and `w9:p3`.
Input markers appeared only in their target panes. Existing panes remained present.
Command-R refreshed both terminal grids and preserved `w9:p3` selection.
Multiline paste stayed in the shell editor until Return. Each command then produced its expected output.
The clipboard tool reported a timeout, but UI inspection showed one delivered paste. The test did not retry the paste.
Evidence: `/private/tmp/rai09-391wxjtr/endpoint4-checks.json` and its referenced stage records.
App SHA-256: `d365d2ebc946cc0d1154fe70e61c7d484dc21c0f864e0b5b79553ce0298fbdc1`.
This build precedes the semantic keyboard and startup activation fixes.

The semantic keyboard build passed application cursor mode and Kitty report-all-keys checks.
Herdr encoded Up as `ESC O A` and Enter as `CSI 13 u` for the requested terminal modes.
Evidence: `/private/tmp/rai09-391wxjtr/endpoint5-keyboard-checks.json`.
App SHA-256: `3d9554bd1b0738be7587f9b590fd002e4473e96f4eca2634fae2638224a8e44f`.
A rapid focus-and-type check then exposed input rejection after metadata revisions advanced.
The fix preserves queued input across metadata changes and invalidates it after navigation.
A regression test checks metadata updates and navigation away from, then back to, the same pane.
The corrected app passed rapid directional focus and typing without an identity error.
Window 1 retained `w9:p3` while window 2 selected and used `w1:p3`.
Closing the temporary pane removed only `w9:p3`. Closing the temporary tab then removed only `w9:p2`.
Closing window 1 preserved window 2, its selected pane, and working input.
The final server snapshot retained every original pane. No test-created panes remain.
Evidence: `/private/tmp/rai09-391wxjtr/endpoint6-checks.json` and its stage records.
Final app SHA-256: `107c11890245f94dd61b5c897ddb767f05cfb313f4d55cf83689ac4f83aefea3`.
Final gate logs: `/tmp/rai09-full-mac6-tests.log` and `/tmp/rai09-full-ios6-tests.log`.

Historical two-window checks verified separate input targets and pane preservation.
Evidence: `/private/tmp/rai09-391wxjtr/endpoint-window-e2e.json`.
These checks do not complete E01, E02, or phone endpoint acceptance.

Reviews found paste boundary loss, blocked input writes, reconnect cache reuse, keyboard mode loss, and a startup action race.
The worktree contains fixes and regression tests for these defects.
The latest review could not finish because the Codex CLI reached its usage limit.
Review log: `/tmp/rai09-endpoint-review5.log`. No clean final review exists for this slice.


The worktree contains app isolation, missing-Herdr startup recovery, lazy file-access guidance, and pane scroll indicators.
It also contains acknowledged event startup, reconnect snapshots, pane filter replacement, and write replay prevention.
The final Mac suite passed 714 tests, with two skipped. The final phone suite passed 239 tests.
Input identity fixes also passed 28 focused tests. The final isolated release build passed.
Later focused tests passed for agent explanation, closure identity, retained clients, and event transport.
The build-script suite previously passed 16 tests. These results do not replace app end-to-end acceptance.
The event and scrollbar `autoreview --mode local` run reported no actionable findings.
Review result: `/tmp/rai-herdr09-events-review.json`.
The Phase 1 safety review also passed: `/tmp/rai-herdr09-phase1-fixes-review2.json`.
Agent explanation passed both builds, the focused transport tests, and isolated app success checks.
Its review passed: `/tmp/rai-herdr09-explanation-review3.json`.
Both interfaces use bounded requests. Mac sheet dismissal and connection changes cancel the pending request.
Bridge requests use separate sockets and do not block later phone messages.
Stalled app-interface scenarios remain unverified; socket tests cover deadlines, cancellation, and concurrent snapshots.
Xcode could not collect simulator diagnostics because its helper could not find `simctl`; the iOS test gate passed.

Computer Use connects to the isolated Mac apps and simulator.
The fresh-install lab `/private/tmp/rai09-g4a9qcqi` uses bundle suffix `e2e-75000340ad39`.
Startup without Herdr displayed setup guidance without a sidebar spinner.
Retry recovered after private binary installation without restarting Rai.
Startup and installation showed no automatic permission dialog.
The earlier lab `/private/tmp/rai09-5o1izl6n` verified denied config reads, optional help, dismissal, and recovery.
Evidence: `/tmp/rai-herdr09-e2e-9s3t125t.json`.
Hook denial and light appearance checks remain open.

The scrollbar and event lab uses `/private/tmp/rai09-391wxjtr`, bundle suffix `e2e-56b425104c06`, and bridge port 56341.
Its phone uses simulator `2F9F0DF0-F78E-4DF2-A7E7-8AE1AE30CE8D` and an isolated app identity.
Mac UI checks verified translucent overlays, idle hiding, dragging, and unchanged visible text positions.
Dragging and Back to live sent no additional wheel reports to a mouse-reporting test application.
Evidence: `/private/tmp/rai09-391wxjtr/scrollbar-e2e.json`.
Phone accessible scrolling moved through history. Computer Use drag gestures failed in Rai and on the simulator Home screen.
Phone touch-scroll validation remains open; the Home screen result does not establish an app defect.

Group previews appeared on both apps. Cancel preserved all group members.
Mac closure rejected a preview after another test client added a group member.
Mac and phone group closures preserved the unrelated workspace.
After server handoff, the phone rejected its old group confirmation and preserved both group members.
The Mac ordinary Close action displayed its group protection message.
The phone now exposes workspace actions through a visible menu button.

Both apps launched the synthetic Muse fixture without a provider connection.
A phone command changed Muse to Working and appeared once in its terminal output.
Both apps displayed Muse status. Phone commands changed the fixture from blocked to working on both apps.
Both explanation sheets displayed Herdr detection results. Yogev subsequently excluded real Muse lifecycle checks.
Evidence: `/private/tmp/rai09-391wxjtr/agent-explanation-e2e.json`.

The Mac update control reported that Herdr 0.9.0 was current and retained the verified protocol-22 executable.
Mac cached and new terminals worked after an incompatible fixture replaced the isolated installation.
Phone input and observation also worked. Four app child processes mapped the retained executable.
The test restored the verified installation afterward.

Mac handoff completed twice. The second run preserved all sampled shell and Muse process IDs.
Herdr assigned new terminal IDs during handoff. Both apps recovered their resource lists.
Phone client update and live handoff controls now use confirmed connection identities and the Mac audit gate.
The isolated phone update reported Herdr 0.9.0 as current. Cancellation preserved the running server.
Phone handoff completed and preserved all sampled shell and Muse process records.
The phone rejected a confirmation after the Mac connection changed. The test server remained unchanged.
An older Mac capability set disabled both controls. The sheet explains how to enable them.
Review passed: `/tmp/rai-herdr09-management-review2.json`.
Evidence: `/private/tmp/rai09-391wxjtr/phone-management-e2e.json`.
Socket loss and audit rejection have regression tests. App fault checks for these paths remain open.
Other phone administration features remain unimplemented.

Phone pane navigation now omits shared selection messages when the Mac advertises independent observation.
Legacy hosts retain the previous selection sequence. Regression tests cover both paths.
The isolated phone opened shell `w1:p3` while the Mac displayed `Handoff Group Main`.
Phone input produced the test marker only in `w1:p3`. The Mac terminal and sidebar selection stayed unchanged.
Server snapshots preserved workspace, tab, pane focus, and every pane layout after phone navigation and input.
Evidence: `/private/tmp/rai09-391wxjtr/independent-observation-e2e.json`.
Review passed after removing a private-state test assertion: `/tmp/rai-herdr09-independent-observation-review2.json`.
A rotation attempt displayed `w1:p1` after the phone previously displayed `w1:p3`. Input then reached `w1:p1`.
A repeat attempt preserved `w1:p3`, including its input marker. The cause remains unresolved; rotation acceptance stays open.
Backgrounding and resuming the app preserved `w1:p3` during the repeat check. This does not establish forced-suspension coverage.
All sampled server focus fields and layouts remained unchanged through these checks.
Phone machine selection and forced suspension remain unverified or unimplemented. Native Mac window checks appear below.

Evidence with app hashes and scenario limits: `/private/tmp/rai09-391wxjtr/phase1-e2e.json`.
Supporting files include `retained-client-e2e.json`, `handoff-e2e.json`, and the group state records in that directory.
A separate inactive endpoint probe decoded the generation-1 welcome and boot identity.
That probe does not establish native app transport support.

Mac pane creation, a new-pane Muse status event, and pane closure appeared on both apps.
Replacing the owned server removed stale panes from both apps without restarting Rai.
A new workspace then appeared on both apps. Phone input reached the replacement server and displayed once on both apps.
Evidence: `/private/tmp/rai09-391wxjtr/event-delivery-e2e.json`.
Socket fixtures cover acknowledgement, changes during snapshot loading, replacement filters, invalid initialization, and cancellation.
They cover Herdr 0.8.2 and 0.9.0 response shapes. Mixed-version app checks remain open.

Lab SSH actions remain disabled until a disposable SSH account and configuration are available.
The quality check reports test classification, test duplication, class size, and recent-change findings.
The latest run reported 97 gating findings across the uncommitted branch: `/tmp/rai09-endpoint-quality5.txt`.
Do not interpret its output as a clean quality gate.

Yogev requires isolated app end-to-end tests for every feature on macOS and iOS.
This requirement applies throughout the [implementation plan](herdr-0.9-support-plan.md), not only before release.

## Isolation contract

Create a unique test run identity and record every resource that the run creates.
Verify the resolved runtime targets before the first test action.
Stop the run if any target resolves to a live app, server, credential store, or user workspace.

| Resource | Required isolation |
| --- | --- |
| Mac application | Launch the tested bundle from a test directory with a separate process and verified test preferences. |
| Application data | Use dedicated paths for application support, history, caches, logs, hooks, reopen records, and machine profiles. |
| Credentials | Use test pairing records and a separate credential namespace. Never load live device credentials. |
| Bridge | Bind a unique test port and test sockets. Pair only the test phone instance. |
| Herdr | Use a pinned test binary and named sessions with ownership markers and distinct sockets. |
| Herdr shared state | Isolate machine catalogs, config, update state, integration files, and detection manifests before testing their mutation. |
| Repositories | Use disposable repositories, worktrees, and synthetic terminal content. |
| SSH endpoints | Use test accounts or disposable hosts with dedicated configuration and session state. |
| iOS simulator | Use a dedicated simulator and test app container. Keep pairing and notification state separate. |
| Physical iPhone | Use a separate test app identity, sandbox push environment, test pairing, and dedicated notification registrations. |
| External input | Bind device tests only to the isolated app. Keep live keyboard integrations outside the test target. |
| Updates and stop actions | Target only test binaries, app copies, and servers owned by this run. |

A development bundle name and a changed `HOME` value do not prove isolation.
The current test guide reports shared Application Support paths between app builds.
The existing Herdr lab uses named sessions because Herdr can resolve its home through the account database.
Inspect actual path resolution and add test configuration where isolation controls are missing.
Use a disposable account or machine for state that cannot safely receive a test path.
Do not delete shared files to simulate cleanup.

Before testing, verify the test app's process, bundle path, data roots, sockets, ports, server identity, and phone pairing destination.
Use synthetic sentinel data to verify that separate instances cannot read each other's test state.
Record protected live target identities without reading their credentials or content.
After testing, verify that those targets retain their original process and connection state.
Use path and process evidence to check isolation; an unchanged screen alone does not establish it.

Cleanup must check run ownership before stopping processes or removing files.
Remove only resources created by the run. Preserve evidence needed to diagnose failures.

## Test method and evidence

### Pane scroll indicators

During E04 terminal checks, verify indicators remain hidden while idle and while output arrives.
Scroll one pane. Verify its indicator overlays content with partial opacity, then disappears after scrolling stops.
Verify other panes remain unchanged. Repeat with trackpad momentum, scrollbar dragging, and phone touch scrolling.
Compare terminal columns, rows, content, and pane bounds before, during, and after indicator visibility changes.
Repeat after pane resize, phone rotation, and returning to a cached terminal.
Native iOS indicators must remain overlays and must not reserve grid width or height.

Mac regression tests cover idle dismissal, independent panes, output, buffer content, and three terminal widths.
These tests do not replace the isolated app checks.

Launch the real Mac app and real iOS app for each scenario.
Drive the feature through its user controls, using UI automation where available.
Use CLI and socket calls for test setup, failure injection, and independent state checks.
A CLI-only test does not establish an app end-to-end pass.

Observe the full route: app action, transport, Herdr state, response, and rendered result.
For phone actions, include the real test bridge in that route.
Verify both the visible outcome and the relevant server state.
Capture screenshots or video for visual behavior, plus logs and assertions for routing and lifecycle behavior.
Exercise error handling and reconnect behavior where the feature depends on connections.

Deterministic agent fixtures can establish routing and rendering behavior.
They cannot establish actual agent detection or resume compatibility.
Record real-agent checks separately when the feature depends on a specific agent version.

Every result must include:

- Scenario ID, platform, tested commit, app build, Herdr version, and relevant agent versions.
- Run identity, isolation checks, app process identity, server sockets, and simulator or device identity.
- Setup, UI actions, expected results, assertions, and observed results.
- Evidence paths for screenshots, video, logs, and test reports.
- Pass, fail, or blocked status, with the failure or missing resource stated explicitly.
- Cleanup results and confirmation that the run left live targets unchanged.

Keep an evidence record for each scenario and platform under the test artifact directory.
Use scenario subcases for each operation listed below. Do not infer untested subcases from one successful action.
After a relevant code change, repeat affected scenarios against the new build.
Run the combined suite against the final candidate before marking the release complete.

## Feature scenarios

All rows require separate macOS and iOS results. Partial results appear in the checkpoints and linked evidence.
The combined matrix remains open until every required scenario passes.
The scenario IDs map to the feature contract in the implementation plan.

| ID | Feature | Required app scenario and assertions |
| --- | --- | --- |
| E00 | Fresh installation | Launch without Herdr. Verify setup guidance and Retry. Install the private binary while Rai stays open. Retry and open a workspace. Verify phone guidance and recovery. |
| E01 | Multiple machines | Connect Local and two test SSH profiles. Switch machines and named sessions. Verify machine labels and resource isolation. |
| E02 | Machine operations | Add, rename, enable, disable, and remove profiles. Cancel setup. Verify only the selected profile changes and agents survive disconnection. |
| E03 | Combined agents | Search and filter duplicate agent names across machines. Disconnect one machine. Verify stale rows and correct navigation targets. |
| E04 | Independent views | Navigate with two Mac windows, two phone instances, and a test TUI. Verify every other view keeps its selection. |
| E05 | Shared-tab sizing | Resize and interact on shared and separate tabs. Observe from the phone, rotate, and suspend. Verify size ownership and stable geometry. |
| E06 | Capability compatibility | Connect test servers with different capabilities. Invoke available actions and inspect disabled actions. Verify connection survival and no automatic replacement. |
| E07 | Client presentation | Change copy state, menus, and popup focus in one view. Verify other views retain their state and input target. |
| E08 | Muse — excluded | Yogev excluded this scenario. Preserve prior synthetic fixture evidence without claiming real Muse coverage. |
| E09 | Conditional sidebar styles | Configure ordered text and numeric rules through settings. Change metadata. Verify precedence, missing values, invalid input, and preview accuracy. |
| E10 | Light and dark themes | Import supported overrides and select automatic, light, and dark modes. Change system appearance. Verify both palettes and view isolation. |
| E11 | Pane borders | Select Always, Auto, and Off for single and split panes. Import old boolean values. Verify visible borders and persisted choices. |
| E12 | Pane graphics | Display small and oversized images together. Replace, scroll, resize, delete, reconnect, and rotate. Verify placement, ownership, limits, and cleanup. |
| E13 | Workspace group closure | Close a primary workspace with children. Cancel the group preview, then confirm it. Verify exact targets and unrelated workspace survival. |
| E14 | Worktrees | List, create, open, and remove test worktrees. Remove a background worktree and exercise one-request trust. Verify focus, paths, and trust scope. |
| E15 | Event delivery | Change state during initial subscription and reconnect. Create panes after subscription. Verify final UI state and subsequent event delivery. |
| E16 | Scrollback and selection | Select while output continues, copy, and inject copy failure. Verify retained selection, exact text, history, viewport reads, and uninterrupted agents. |
| E17 | Keyboard, mouse, and paste | Exercise composed keys, Option layouts, pointers, pixel mouse, and multiline paste. Verify exact input and application behavior. |
| E18 | Prompt submission | Submit multiline prompts to idle and blocked test agents. Exit during submission and reconnect. Verify one submission and explicit failure without replay. |
| E19 | Plugins and commands | Invoke commands and plugin actions. Open, focus, and close popups. Verify titles, filtered views, notifications, sounds, and execution context. |
| E20 | Plugin links | Activate matching and unmatched OSC 8 links. Change content before activation. Verify plugin routing, ordinary link handling, and stale-click rejection. |
| E21 | Updates and news | Open news and update controls. Cancel and complete supported test updates. Verify target display, state preservation, and optional handoff. |
| E22 | Persistent sessions | Detach, quit, suspend, reconnect, and explicitly stop a test server. Verify agents survive detach and stop only on the target action. |

E02 must include real SSH transport between isolated endpoints. Two local socket connections do not verify SSH behavior.
E04 and E05 must include simultaneous app instances. Sequential navigation cannot establish view independence.
E08 is excluded by Yogev. Missing Muse does not block this release plan.
E09 must verify color, boldness, and dimming. Include readable states without color and with accessibility text sizes.
E12 must test graphics disabled through both supported configuration names.
E16 must include copy motions, scrollback search, export, and a fixed-workload history and memory comparison.
E17 requires a physical device for external keyboard, pointer, and touch claims.
E19 must include plugin installation, removal, integrations, and notification delivery through dedicated test registrations.
E21 must distinguish Mac host operations from phone app updates delivered through Apple's distribution system.
Test physical push delivery, push action routing, and retraction using the isolated phone build.
Simulator notification injection does not establish APNs delivery.

## Regression and release checks

Map every upstream release fix bullet to a regression scenario or an explicit upstream-only platform result.
Keep upstream-only platform results separate from required Mac and iOS feature passes.
Include real agent lifecycle cases when validating upstream detection changes.

Run duplicate pane-ID tests across machines for input, closure, history, graphics, permission decisions, and notification actions.
Inject network loss during active work on one endpoint. Verify another endpoint remains responsive.
Run mixed Mac and phone versions to verify capability negotiation and update guidance.
Repeat relevant scenarios after server handoff or replacement, using test targets only.

## Completion rule

A feature requires passing isolated app end-to-end results on both platforms before completion.
A failed or unrun scenario keeps the feature incomplete.
Missing hardware, agent access, credentials, or upstream functionality produces a blocked result, not a pass.
Record the exact missing resource and retain the feature in scope.
Unit tests and compilation remain required supporting checks.
