# Integrated validation

Date: 2026-09-09.

Candidate65 passed 941 Mac tests, with seven skips and zero failures, while Herdr was deliberately unavailable.
Its 31 focused tests, 25 missing-Herdr checks, and 16 build-script tests also passed.
Mac app Candidate64 uses identical application source. Candidate65 changes two terminal-pool test fixtures and documentation.
The unchanged Candidate63 iOS source passed 407 tests without failures or skips. Its 45 focused tests passed.
Earlier executable app acceptance remains valid within the limits below. Corrected Mac startup and paired-phone recovery checks passed.
These records do not establish a shipped release or universal E2E coverage.

The current summary supersedes older pending statements below. Historical results retain their original candidate identity.

## Missing-Herdr correction and release gate

The first release attempt exposed a macOS 15 test-process crash that the normal local environment did not reproduce.
The process aborts with `freed pointer was not the last allocation` during `CloseTabReopenTests`.
Base commit `a547578` passes all 16 tests on macOS 15 with Xcode 16.4.
Candidate commit `550090a` aborts with both Xcode 16.4 and Xcode 26.3 on macOS 15.7.9.
The failing test and close-command implementation match the base commit.
No XCTest assertion fails before the abort. A newer compiler alone did not resolve the crash.

[Diagnostic run 34385642444](https://github.com/YogevKr/rai/actions/runs/34385642444) records this comparison.
[Backtrace run 34387300185](https://github.com/YogevKr/rai/actions/runs/34387300185) tests the same source under LLDB.
The single test passes under LLDB. The full suite aborts inside XCTest's error-observation path.
Candidate63 reproduces the same abort locally when `HERDR_BIN_PATH` identifies a missing file.
LLDB stops at `objc_exception_throw`, then Foundation's setter, then `configuredHerdrProcess` at `RaiModel.swift:5677`.
The factory assigns `nil` to `Process.executableURL` when Herdr is absent. The setter raises before process launch.
Swift `do/catch` does not catch this exception. The corrected factory rejects missing paths before process creation.
All callers return failure results or installation guidance. Runtime lookup retains archived clients and uses the injected installed-binary resolver.
Evidence: `missing-herdr64-objc-exception-lldb.log` and `missing-herdr64-candidate63-regression.log`.
The backtrace identifies the missing-executable path. The diagnostic timer patch remains unapplied.

The original 16 close tests now pass with Herdr deliberately unavailable. Three new tests cover missing commands and resolver recovery.
The first corrected full run exposed five terminal-pool assertions that assumed Herdr was installed.
Those tests now use the existing executable injection point with `/usr/bin/true`. Their lifecycle and socket assertions remain unchanged.
All 941 tests then passed under the missing-Herdr condition. The two focused reviews found no actionable defects.
The corrected Mac bundle passed strict signing and isolation checks. The temporary debugger workflow has been removed.
Evidence: `candidate65-mac-pipeline-results.json`, `candidate65-app-source-reconciliation.json`, and `missing-herdr65-autoreview.json`.

The separate startup app showed installation guidance, survived three Retry clicks, and remained responsive during failed commands.
Installing the private Herdr fixture and selecting Retry restored a shell workspace without restarting the app.
No Full Disk Access prompt appeared during launch, retries, installation, or recovery.
The app retained PID `73430`; its owned Herdr server uses PID `78322`.
Evidence: `/private/tmp/rai09-qol61vru/startup64-e2e-results.json`. Signed startup-app code matches Candidate64 before signing.

The primary Mac app update retained the `commands22` session and restored its workspace list.
Both paired phone simulators restored workspace lists without another pairing code. The secondary phone retained its captured History view.
Both phone processes established connections to the updated Mac's private bridge port `56341`.
Evidence: `candidate64-mac-install.json` and `candidate64-primary-recovery-results.json`.

Publication still requires final-commit CI, release signing, notarization, upload, and external distribution checks.

## Candidate63 runtime checkpoint

Candidate63 contains 461 frozen files. Both build pipelines verified their source hashes after all checks.
Its source manifest SHA-256 is `48f0117a1b01fba27ac9dd14fb5ffa2f16e3ab0b500dbfe241f90062b0574a80`.
Build, strict signature, and Mac isolation checks passed. The standalone phone app contains no test plugins.
Evidence: `candidate63-mac-pipeline-results.json` and `candidate63-ios-pipeline-results.json`.

The Mac input queue passed a single 621-character ASCII burst through the installed app.
Physical Option-key composition then produced both accented characters exactly once.
The recorder received all 630 expected bytes, including the final Ctrl-C. The app retained its connection.
The pending Option+e key sent no bytes before character commitment.
Direct CUA Unicode typing omitted accents in an earlier attempt. That failed attempt remains recorded.
Evidence: `candidate63-mac-burst-composition-results.json` and `candidate63-mac-burst-ui-results.json`.

The phone passed a single 623-character ASCII burst and both composed accents.
The recorder received all 632 expected bytes, including Ctrl-C. The app retained its connection.
The pending Option+e key sent no premature bytes.
Evidence: `candidate63-phone-burst-composition-results.json`.

Both phones restored workspace lists without another pairing code. The secondary phone restored its native input pane.
Evidence: `candidate63-pairing-ui-results.json` and `candidate63-paired-install.json`.

Mac History search retained the exact lowercase query `yogev` after focus moved to captured text.
Evidence: `candidate63-mac-history-search-ui.json`.

Candidate63 batches adjacent committed text and preserves target, revision, key, paste, epoch, and popup boundaries.
Both original models failed the burst regression. The reviewed correction passed focused and full suites.
A mounted phone switch regression verifies OFF and ON state persistence.
Phone toolbar checks now verify Extend OFF/ON, Text Start, Next Word, and Next Character through CUA.
Next Word selected `UNMATCHED`; Next Character selected `U` after moving to text start.
Direct toolbar copying remains uncertain under CUA. Existing clipboard failure and retry app evidence remains valid.
Evidence: `candidate63-phone-selection-ui-results.json`.
Reviews: `input67-autoreview.json`, `/tmp/rai09-search63-review.json`, and `/tmp/rai09-selection70-review.json`.

## App identity

- Lab root: `/private/tmp/rai09-391wxjtr`.
- Mac bundle: `gr.krig.rai.lab.e2e-56b425104c06`.
- iOS bundle: `com.whetstone.rai.ios.lab.e2e-56b425104c06`.
- Simulator: `2F9F0DF0-F78E-4DF2-A7E7-8AE1AE30CE8D`.
- Candidate63 Mac executable SHA-256: `b286408d87447a5fe9bf1564c6e3fbd00d02b07a5c17063b17dbc0b2d9656ca7`.
- Frozen source: 461 files in `candidate63-source-manifest.json`. This identifies the built candidate.
- Candidate63 source manifest SHA-256: `48f0117a1b01fba27ac9dd14fb5ffa2f16e3ab0b500dbfe241f90062b0574a80`.

## Current test and review results

| Check | Result | Evidence |
| --- | --- | --- |
| Candidate63 Mac focused tests | 92 tests; one optional skip; zero failures. | `candidate63-mac-pipeline-results.json` |
| Candidate63 Mac full tests | 938 tests; seven optional skips; zero failures. | `candidate63-mac-pipeline-results.json` |
| Candidate63 iOS | 45 focused and 407 full tests; zero failures or skips. Standalone build and signature passed. | `candidate63-ios-pipeline-results.json` |
| Candidate63 reviewed changes | All 12 changed code/project files match clean review evidence. Product sources match the frozen manifest. | `release63-review-readiness.json` |
| Candidate62 Mac focused tests | 88 tests; one existing live-lab skip; zero failures. | `/tmp/rai09-candidate62-mac-focused.log` |
| Candidate62 Mac full tests | 934 tests; seven skips; zero failures. | `/tmp/rai09-candidate62-mac-tests.log` |
| Candidate62 Mac bundle | Build, deep strict signature, and lab isolation passed. All 457 frozen files matched after verification. | `candidate62-mac-pipeline-results.json` |
| Candidate62 iOS | Test build, 54 focused tests, 404 full tests, standalone app build, and signature passed. No test failures or skips. | `candidate62-ios-pipeline-results.json` |
| Candidate61→62 review | Codex reported no findings. All 457 frozen and review files matched. | `/tmp/rai09-candidate62-review.json`, `candidate62-ios-pipeline-results.json` |
| Candidate61 Mac focused tests | 11 passed; zero skips or failures. | `candidate61-mac-pipeline-results.json` |
| Candidate61 Mac full rerun | 918 tests; seven skips; zero failures. | `/tmp/rai09-candidate61-mac-tests-after-build.log` |
| Candidate61 Mac bundle | Build, signature, and isolation checks passed. | `candidate61-mac-pipeline-results.json` |
| Candidate61 iOS | Build passed; 11 focused and 389 full tests passed, without failures or skips. | `candidate61-ios-build-verification.json`, `candidate61-ios-test-results.json` |
| Candidate60 previous full gates | 916 Mac tests and 387 iOS tests; zero failures; seven Mac skips. | `candidate60-mac-pipeline-results.json`, `candidate60-ios-pipeline-results.json` |
| Candidate60→61 review | Codex reported no findings. All 456 frozen files matched after review. | `/tmp/rai09-review61-delta.json`, `review61-delta-final-verification.json` |

The initial Candidate61 full run and its focused timing retry failed one duration assertion.
`testOversizedUnterminatedPromptResponseFailsBeforeDeadlineWithoutReplay` exceeded three seconds in both runs.
The final full rerun passed. Preserve the initial failures; the passing rerun does not explain their cause.
Logs: `/tmp/rai09-candidate61-mac-tests.log` and `/tmp/rai09-candidate61-mac-timing-retry.log`.

Static quality remains non-clean. Existing classifications and clean code reviews do not change that gate result.
Later source changes require their own candidate identity, tests, and review.

Candidate62 Mac compilation used a private copy of Candidate61's warm cache.
The pipeline moved copied debug and release module caches before compilation because their precompiled headers contain previous paths.
The focused and full suites passed on their first runs. No Candidate62 Mac app installation occurred during this pipeline.
Seven optional Mac checks remained skipped. Their exact requirements appear in `candidate62-mac-skips.json`.
Those skips cover release archives, live endpoint/SSH/closure fixtures, and the typing benchmark.

Candidate62's frozen manifest includes documentation from its source freeze.
Later edits to this report and release notes record subsequent evidence. They do not change the frozen candidate's identity.

## Implementation scope findings

The [support plan](herdr-0.9-support-plan.md) requires product controls as well as app validation.
The targeted source audit found two implementation gaps in frozen Candidate61.

| Gap | Source evidence | Required behavior |
| --- | --- | --- |
| Popup links | `EndpointPluginLinkInvocation.links`, `capture`, and `validate` reject active popups. Both native link callbacks use this path. | Activate popup links with popup identity and stale-content checks. Preserve the underlying pane. |
| Native copy motions | Phone selection sheets expose Done and Share. Toolbar arrows send terminal input. Native `pane.copy_motion` only finds history's final column. | Expose selection motions through phone controls and keyboard shortcuts. Support equivalent native Mac selection actions without terminal writes. |

Legacy Mac copy mode already exists. Native text selection and history copying also exist.
They do not provide the missing explicit native copy-motion controls required by the plan.
Candidate62 addresses both gaps. Candidate63 completed executable acceptance, retaining the stated upstream and measurement limits.

Popup browser links use a separate HTTP(S) route with boot, terminal, surface, projection, and displayed-link checks.
Pane plugin routing remains separate. Herdr exposes no popup plugin-link activation API.
Custom popup schemes report unsupported routing. Wrapped explicit OSC8 links work; wrapped plain URLs remain unsupported.
Twenty focused link tests and scoped Codex review passed. Candidate62 also passed integrated Mac and iOS compilation and tests.
Runtime checks remain separate.
Evidence: `popup-links63-handoff.json` in the lab root.

Captured text views now provide character, word, line-edge, and text-edge selection motions.
Move Selection, Extend, Select All, and Copy controls act on the captured text.
Phone arrows move characters; Option moves words; Command moves to line or text edges. Shift extends the selection.
Mac text views use native equivalent shortcuts. These selection operations send no terminal commands.
This implementation status does not establish completed hardware-keyboard or app acceptance.

Native metadata rows also now expose status words in their accessibility label, including server-provided state labels.
An explicit state-text token suppresses the icon's duplicate spoken label. Visible rows, styles, and layout stay unchanged.
Fifteen focused metadata tests and scoped Codex review passed. Candidate62 integrated checks also passed.
Candidate62 AX output now exposes status names on both platforms, according to the parent’s current UI observation.
Actual VoiceOver speech remains unmeasured.
Evidence: `metadata-a11y62-handoff.json` in the lab root.

The upstream native endpoint excludes `plugin.pane.open`. Its ordinary API cannot establish native popup ownership.
Native plugin controls must report this unavailable capability. Supported configured popup commands provide the fixture launch route.
The fixture has two additive commands and guarded apply/restore tools. The parent owns activation and app validation.

Upstream popup ownership follows the tab. Clients selecting the same tab share popup presentation and can route input there.
Earlier popup independence checks used different tabs. They do not establish popup invisibility between clients on the same tab.
Source evidence: `popup62-upstream-policy.json`. The parent observed the popup on a second phone selecting the same tab.

Popup pixel packets also depend on upstream graphics activation for the popup's internal pane ID.
The parent observed cell-coordinate fallback despite DEC1016 and valid popup pixel geometry.
The supported graphics API resolves workspace pane IDs. Popup IDs have no workspace registration, so that API cannot activate their layers.
This is an upstream capability limit. No product or upstream patch bypasses it.
Raw evidence: `popup-input-s_wq2bfv/pixel-1788967956050734000.jsonl`. These packets do not establish successful popup pixel input.

Popup mouse routing, composed input, pixel input, optional file-access help, and notification sound have implementation paths.
Their remaining acceptance checks appear below. This targeted audit does not certify every implementation path.

## Final acceptance and limits

Candidate62 phone composition passed exact byte validation. Dead keys sent no premature bytes; completed accents arrived once without Escape bytes.
Evidence: `phone62-composition-ui-results.json`.

Phone popup HTTPS and custom-scheme checks passed. The HTTP link opened another Safari tab, which upgraded the same path to HTTPS.
Return closed the owned popup before its deadline. Six protected hashes matched.
Evidence: `popup-input-s_wq2bfv/links62-ui-results.json`. Mac popup link activation remains limited by unavailable held-modifier clicks.

History search autocorrected `yogev` to `You’ve`. A reviewed four-line change disables correction and iOS automatic capitalization.
Candidate63 includes this change. Both platforms preserved lowercase queries after focus changed.
Evidence: `candidate63-mac-history-search-ui.json` and `candidate63-phone-history-search-ui.json`.

Fast Mac typing disconnected its native view after a partial command. Reconnect restored the same pane.
The input queue has a 64-event overflow limit. Candidate63 passed the regression with bounded text batching.
The original failure and the verified correction remain separate evidence.

Phone pixel taps passed after moving the legacy Mac view away from the fixture pane.
Two taps within one cell produced pixel positions `(181,454)` and `(183,454)`, with matching press and release packets.
The previous legacy attachment used different cell dimensions and caused cell-coordinate fallback.
Evidence: `phone62-pixel-ui-results.json`. CUA drag delivered no motion sequence, so physical drag remains unverified.

The popup closed with Return. The original config was restored and reloaded; only the two original commands remain.
The owned popup plugin was unlinked and the owned pixel layer was cleared. Both protected recorder hashes remained unchanged.
Evidence: `popup-input-s_wq2bfv/cleanup63-results.json` and `cleanup63-native-results.json`.

Candidate63 closed the selection, input, search, and retained-history checks. The API and measurement limits remain disclosed.

| Check | Required evidence |
| --- | --- |
| Final selection controls | Passed character, word, line, and document motions. Existing unchanged exact-copy and failure/retry paths retain their prior app evidence. |
| Phone composition | Passed on Candidate62. Preserve exact byte evidence when integrating subsequent changes. |
| Popup links | Phone passed. Mac direct activation remains unverified because CUA lacks held-modifier clicks. |
| Ordinary phone pixels | Passed distinct pixel taps and matched press/release on Candidate62. CUA drag remains a measurement limit. |
| Historical/current history comparison | Completed 400-row retention and six-stage RSS observations. Presentation and geometry limits prevent a memory-savings claim. |

Candidate63 is installed on the Mac and both phones. Both phones retain pairing despite changed simulator container paths.
Installation evidence: `candidate63-mac-install.json`, `candidate63-paired-install.json`, and `candidate63-pairing-ui-results.json`.
The parent observed idle/unknown names in Candidate62 AX labels on both platforms. Actual VoiceOver speech remains unmeasured.

Popup mouse and keyboard passed on Mac. Phone tap and Return passed; the popup preserved the underlying shell.
The phone drag tool produced no packets. This is a measurement limit, not a confirmed product defect.
Evidence: `popup-input-s_wq2bfv/mouse61-ui-results.json`. These checks used Mac Candidate61 and phone Candidate60.

Native plugin-pane launch and popup pixel activation remain upstream API limits, as described above.
Sound output remains unmeasured because platform playback lacks reliable caller-PID attribution. An empty exact-app probe does not establish silence.
Mac Command-click, actual VoiceOver speech, and physical-input claims remain explicit measurement limits.
These exceptions prevent an unqualified claim that all requested E2E measurements passed.

Current reconciliation: `candidate63-current-acceptance-map.md` and `.json` in the lab root.
`final61-gap-audit.md` remains historical evidence. Its older open items do not expand the current gate.

Existing RSS samples contain 400 numbered rows and 15,109 captured characters on each platform.
Phone46 measured 290,224, 294,864, and 286,368 KiB before, after one, and after three captures.
Mac48 measured 136,480, 144,240, and 133,680 KiB. Its baseline followed an earlier capture.
These samples establish bounded observations, not improvement or long-term memory bounds.
Evidence: `history46-memory-comparison.json` and `machines48-ui-checks.json`.

Physical keyboards, pointers, touch, and APNs require physical-device evidence for those specific claims.
Simulator composition and app checks can proceed separately. Simulator injection does not establish APNs delivery.
The upstream automatic-title defect, shared history position, tab-scoped popups, and popup pixel fallback remain documented limits.
Muse remains excluded. Apple distribution remains separate release work.
Existing iOS build39 now reports external `IN_BETA_TESTING` in GitHub run34367947388.
This status does not ship Candidate62 or the planned build40. Evidence: `testflight39-current-status.json` in the lab root.

## Final selection and memory evidence

Candidate63 phone Line End selected `UNMATCHED OSC61`. Line Start contracted that selection to empty.
Text End extended selection through the final prompt and scrolled to the capture end.
Text Start then collapsed selection and returned to the first line.
Character, word, and Extend checks also passed. Mac motion checks passed earlier on unchanged selection code.
Evidence: `candidate63-phone-line-document-motion-ui.json`, `candidate63-phone-selection-ui-results.json`, and `selection62-cua-validation.json`.

Existing exact-copy and failure/retry app checks remain valid for unchanged clipboard paths.
An additional CUA toolbar-copy attempt produced uncertain routing. It establishes neither another pass nor a confirmed product defect.
No per-motion clipboard result replaces the existing exact-copy evidence.

Both historical and current apps retained all 400 corpus rows through their interfaces.
Historical Mac and both Candidate63 apps copied identical 14,902-byte captures, including the command and prompts.
The corpus contains 14,818 bytes, 400 numbered rows, and its completion marker.
Historical phone search found all 400 rows. Its legacy interface supplied no raw full-history export.

| Stage | Historical Mac KiB | Candidate63 Mac KiB | Historical phone KiB | Candidate63 phone KiB |
| --- | ---: | ---: | ---: | ---: |
| Empty | 68080 | 86912 | 311792 | 321792 |
| Loaded | 69600 | 88704 | 308464 | 326752 |
| First capture | 70416 | 112176 | 287840 | 359872 |
| Second capture | 75088 | 113520 | 330576 | 333600 |
| Third capture | 72336 | 110480 | 318688 | 348208 |
| Closed | 71536 | 106224 | 248160 | 351024 |

Values are absolute RSS medians from five samples per stage. No compiler ran during sampling.
The shared layout matched 120×40 before current sampling. Closing phone history changed the final layout to 52×44.
Every sampled scroll record reported 38 viewport rows. Geometry was not controlled throughout.
Fonts, capture routes, listener bindings, process lifetimes, and closed-stage actions also differed.
Idle RSS varied. These observations establish no memory savings, isolated transport improvement, leak, or long-term memory bound.
Evidence: `transport-memory-measure62/comparison63-report.md` and `transport-memory-measure62/comparison63-results.json`.

## Recent completed app checks

- Candidate58 live rename updated both root views without refresh. Candidate60 closure removed the test workspace from both roots.
- Candidate58 phone and Candidate60 Mac history sheets retained selection after injected copy failure. Explicit retry copied exact text.
- Candidate59 Mac composition sent no premature dead-key text and delivered `MAC59-éü-END` exactly once.
- Candidate60 used two Macs and two phones to compare independent history queries, copying, menus, and popup text/Return routing.
- Candidate61 Mac pixel input passed distinct points within one cell, drag/release, and repeated checks after resize.
- Candidate61 passed optional denied-hook help, light appearance, access recovery, and new-window/restart suppression.
- Candidate60 phone metadata and token forms remained readable and reachable at the largest accessibility text size.
- Candidate61 Mac Links and Candidate60 phone tap opened the unmatched explicit OSC8 URL. The plugin recorder stayed unchanged.
- Both apps rejected stale plugin links after changed surfaces arrived. The plugin recorder stayed unchanged; no browser opened.
- Both apps completed blocked-agent rejection, terminal-exit handling, draft retention, and no-replay checks.
- Both apps completed independent worktree opening and background removal. Unrelated selections remained unchanged.
- Legacy boolean border imports passed on both platforms. Local history sharing and different-width history captures also passed.

Evidence: `subscription58-ui-results.json`, `subscription60-ui-results.json`, and `e17-candidate59-composition-results.json`.
Clipboard evidence: `clipboard58-phone-history-ui.json` and `clipboard60-mac-history-ui.json`.
Other records: `e20-gate-*-watch.json`, `prompt48-ui-results.json`, `prompt49-phone-exit-results.json`, and `e14-ui52-results.json`.

New records: `e07-candidate60-ui-results.json` and `pixel61-mac-ui-results.json`.
Help evidence: `help61-ui-results.json`. The test restored the hook path, file mode, and dark appearance without installing hooks.
Denied access used a controlled POSIX permission failure. The test changed no operating-system permission.
Accessibility evidence: `accessibility60-phone-ui-results.json`. The test restored Large text size and cancelled all form edits.
That check did not measure VoiceOver speech. Candidate62 AX output now exposes the semantic status names.
Unmatched-link evidence: `unmatched61-ui-results.json`. Both browsers opened the expected HTTPS target; Mac used its explicit browser fallback.
The Mac result does not establish direct Command-click behavior.
E07 did not expose exact selected ranges after focus changes. It did not test TUI copy mode or popup mouse/links.
Mac pixel checks did not resize while holding a button. They establish no phone-input result.
The protected prompt recorder retained its recorded hash.

The separate `popup-input-s_wq2bfv` script is prepared. The parent linked its plugin after preparation.
It provides cell/pixel mouse modes, unique HTTP(S) OSC8 links, custom-scheme rejection, raw input logs, and a 180-second limit.
Nine fixture checks passed. Ten isolated configuration checks passed, including conflict rejection and exact byte restoration.
The additive proposal preserves existing commands. Its guards verify configuration permissions and the current plugin registration file.
The parent applied the guarded configuration and exercised native popup commands. Preparation alone did not establish these runtime results.
Native `command.invoke` must use a fresh endpoint-issued command ID after the parent reloads configuration.
Do not use ordinary-socket plugin open envelopes for per-view evidence.
Evidence: `popup-input-s_wq2bfv/handoff.json` and `popup-input-s_wq2bfv/SETUP.md`.
Configuration evidence: `popup-input-s_wq2bfv/config-addition.diff` and `popup-input-s_wq2bfv/config-guard-offline-results.json`.

## Historical checkpoints

The sections below preserve earlier observations. Their pending statements describe those checkpoints, not the current status above.

## Graphics configuration

CUA verified both apps against three private Herdr servers.
Stable false and legacy false hide terminal images. Terminal text remains visible.
Stable true overrides legacy false. Both apps display RGB, alpha composition, and images behind text.
Both apps display the orange layer uploaded through `pane.graphics.set`.

Evidence: `graphics36-checks.json` in the lab root.
The lab manifest now targets its original `commands22` server.

## Metadata

CUA created an Equals rule for workspace name `Commands Lab` on each platform.
The Mac preview and saved sidebar use red. The phone preview and saved pane list use blue.
These different colors confirm separate client preferences.
The Mac canceled a default-layout reset. The saved rule remained active.

Candidate39 includes grouped Mac forms to correct clipped editor labels.
Simulator accessibility `setValue` enters complete field values. Native simulated typing dropped characters during this check.

## Theme regressions

The Mac theme editor lists eighteen Herdr themes and Rai Default.
Candidate39 fixes the observed theme regressions. Mac theme saves preserve images.
The phone theme sheet opens. TOML import applies Dracula and a custom accent.
Mac cyan and phone green accents confirm separate client preferences.
Candidate42 phone theme save preserved the RGB, alpha, and behind-text image layers.
The phone accent changed from green to magenta. Candidate43 also shows a readable white Panes title under Dracula.

## Scrolling and worktrees

Mac wheel scrolling moved the private `w1:p5` pane from live output to offset 51.
The overlay appeared during scrolling and disappeared while idle. Text position and grid width remained stable.
Phone page controls changed history offsets and displayed temporary overlays. Direct touch dragging remains unverified through CUA.

Both apps created disposable worktrees through their native sheets. Each action cleared the one-action trust switch.
Phone creation selected its new workspace. An earlier Mac navigation defect was fixed and retested in candidate43.
Candidate39 Mac opening selected the returned worktree pane.
Cancel preserved its checkout. Normal removal rejected untracked files and preserved their contents.
Force removal displayed its data-loss notice, then removed the owned checkout and its workspace.
Phone creation preserved Mac selection. Mac creation preserved the phone's previous pane.

## Prompts, links, and notifications

Both apps submitted exact multiline Unicode prompts once. Both apps cleared the editor after success.
Both apps rejected the invalid foreground-process fixture and preserved `REJECT37` in the editor.
The recorder retained three records: one CLI probe and one successful submission from each app.

Mac plugin disable and enable matched the server inventory.
Mac Links actions and phone native taps invoked two plugin URLs once each.
Each action retained the expected plugin, action, handler, and pane identities.
Phone tapping the plain URL opened its exact path in Safari. The plugin recorder did not change.
Direct Mac Command-click remains unverified because CUA lacks a held-modifier click operation.

Both apps displayed one matching test notification in notification history.
Sound was disabled. Candidate46 later verified notification replay after native transport recovery.
Both app pane lists displayed the Idle Lab filter and the two expected Codex fixtures.
The Working filter showed an empty list on both apps. Clearing it restored both workspace lists.

Evidence: `candidate39-checks.json`, `text37-prompts.jsonl`, and `plugin39-actions.jsonl` in the lab root.

## Review limits

The earlier review hit a Codex usage limit. The full candidate48 bundle later exceeded the input-size limit.
A scoped product review then ran and found six actionable defects. Candidate49 addresses those defects.
The product review and separate test review are running again. Neither has a passing closeout result yet.
Logs: `/tmp/rai09-review49-product.log` and `/tmp/rai09-review49-tests.log`.

Run the complete feature matrix against the final combined source snapshot.
Do not count these partial checks as complete release validation.

## History capture checkpoint

Candidate39 Mac captured all 400 numbered fixture rows. Search found 401 matches, including the completion marker.
Next and Previous changed the selected match. Native copying preserved one exact row in the search field.
Export saved 14,935 bytes. Every numbered row remained present.
New live output did not change the open capture. Reload then included the new marker.
Evidence: `history39-mac.txt` and `candidate39-checks.json` in the lab root.

Candidate39 phone history failed after a surface revision changed. The failure incorrectly disconnected its endpoint.
Candidate42 includes native-surface refresh and bounded retries for stale read revisions. Its direct phone retest passed.
The focused bridge regression passed and preserved its connection after two revision changes.
The phone app retest passed search, copying, export, immutable capture, and Reload.

## Upstream graphics reload limit

Herdr 0.9 rejects live graphics policy changes with a partial reload result.
Its diagnostic requires a Herdr restart and states that it kept the current setting.
The isolated fixture configuration was restored. Its original server process stayed running.
Evidence: `graphics42-reload-limit.json` in the lab root.

## Candidate43 layout and closure

Both apps resized a split from 0.5 to 0.55 and restored 0.5.
Both moved a pane beside another pane, into a new tab, and into a new workspace.
Both reordered tabs and workspaces. The owning app followed each returned pane identity.
Both rejected single closure of a primary workspace with linked workspaces.
Both displayed exact group membership. Cancel preserved each group.
Confirmation closed only the reviewed group. Independent server checks confirmed that unrelated workspaces survived.

Both apps applied and cleared window title events. The phone event preserved the Mac title.
Evidence: `candidate43-checks.json` and the `layout43-*` records in the lab root.

## Candidate43 remote launch

The Mac launched `mac43-launch` on Lab One `w2:p6`.
The phone launched `phone43-launch` on Lab One `w2:p7`.
Each UI action produced one recorder entry. The total increased from five to seven.
Lab Two retained its existing Claude fixture.
These local recorder programs do not establish real Codex lifecycle detection.
Evidence: `launch43-evidence.json` and `machines-ui-launch-panes.json`.

## Phone history retest

The phone found 401 matches and selected the expected next and previous matches.
Native selection copied `SCROLL38` into search.
Export saved all 400 numbered rows in `history42-phone.txt`.
New live output remained absent from the capture until Reload.
Reload included `HISTORY42_PHONE_NEW` without disconnecting.

## Remaining limits

Direct Mac Command-click, phone touch dragging, and notification sound remain unverified.
Simulator checks do not establish physical APNs delivery or hardware input behavior.
Structured review is running. Static quality reports remain non-clean.
The candidate46 repository-wide scan reports 154 gating findings. Its two changed product files contain no gating rows.
Report: `/tmp/rai09-candidate46-quality.json`. This result is not a clean quality gate.
The scoped static audit classified 95 findings without finding a new correctness defect.
Its findings include maintenance concerns and false dead-code reports. See [static audit](herdr-09-static-audit.md).

## Candidate43 plugin and integration checks

Both apps reviewed the official Telegram example on SSH Lab One, then canceled installation.
The review resolved commit `18709cdc851dd63ed0543eb8388343a5446fd8d8`.
The preview showed three actions, one event, zero startup commands, and zero build commands.
No approval ran those plugin actions. Independent checks found no remaining installer and an empty remote inventory.
The initial review failed because the disposable container lacked Git. Installing Git in that container enabled review.

Both apps reviewed and canceled the same source for local `commands22`.
The primary Mac window remained on `graphics36-stable` throughout both reviews.
Both session inventories retained only the existing enabled validation plugin. Review temporary directories were removed.

The phone disabled, enabled, and unlinked its zero-command lifecycle fixture.
Cancel preserved the registration. Unlink removed the registration and preserved its source files.
The phone canceled managed removal, then confirmed removal of the managed fixture.
Independent checks confirmed that its files disappeared and the existing plugin remained enabled.

The Mac installed Claude integration in SSH Lab One. The phone installed Codex integration there.
Refresh showed `current` for both integrations.
Independent checks verified expected hook files, permissions, and upstream asset hashes inside `/home/labone`.
These checks establish installation controls. They do not establish real-agent hook execution.

Evidence: `/tmp/rai-phone-plugin43-after.json`, `/tmp/rai-integration43-after.json`, and `/tmp/rai-named-local43-audit.json`.

## Candidate43 phone machine controls

The phone renamed SSH Lab Two, disabled it, enabled it, and restored its original label.
Independent catalog checks confirmed the original label and enabled state. Lab One remained unchanged.
Combined search displayed matching `w1:p1` rows from both SSH machines with distinct machine and agent labels.
The blocked filter retained only Lab Two's Claude row. Selecting that row opened Lab Two's pane.
Independent checks confirmed that Lab One retained its previous focus.
Evidence: `machines43-phone-management.json` and `machines43-labone-after-phone-search.json` in the lab root.

## Candidate43 worktree completion checks

The phone opened its existing checkout and selected `w4:p1`.
Cancel preserved that checkout. Normal removal rejected its owned untracked marker and preserved the marker contents.
Force removal displayed its warning, then removed only the phone checkout and workspace `w4`.
Independent checks confirmed that unrelated workspaces and checkouts remained.
The Mac created `Mac Navigation43` and selected its returned pane `wE:p1`.
Evidence: `phone43-worktree-force-removal.json` and the worktree validation document.

## Candidate44 notification regression

The valid simulator notification exposed repeated close requests for an already closed workspace view.
The Mac rejected the repeated request. Its error interrupted phone navigation.
Candidate44 makes phone view closure idempotent until a new view opens.
Two regression tests cover repeated closure and notification navigation after dismissal.
The full phone suite passed 373 tests with zero failures.
The first foreground notification retest selected Lab One's `w1:p1` without the earlier error.
The background tap also selected Lab One. The stale tap showed the changed-server error and opened no endpoint.
Mac implementation files remain identical to candidate43.
Evidence: `candidate44-checks.json` and `/tmp/rai09-candidate44-ios-tests.log`.

## Candidate45 build checkpoint

Candidate45 contains the phone closure fix, the Mac agent-activation fix, and the visible machine Add control.
Mac agent navigation now activates its captured endpoint before sending pane focus.
The full Mac suite passed 876 tests with six skips and zero failures.
Three live native/SSH tests passed, including agent navigation and unrelated-machine preservation.
The Mac release bundle and phone test build succeeded. Final phone execution and UI retests remain pending.
A copied compiler cache retained absolute paths. A clean build resolved that cache error.
Logs: `/tmp/rai09-candidate45-mac-tests-clean.log`, `/tmp/rai09-candidate45-live-tests.log`, and `/tmp/rai09-candidate45-bundle.log`.
The working tree matches all 411 files in the candidate45 source manifest.
Evidence: `candidate45-final-manifest-audit.json` and `candidate45-checks.json` in the lab root.

## Theme and server-stop completion checks

Both apps passed theme file import, preview cancellation, reset, and separate light/dark accent edits.
The Mac also passed pasted theme import. Saved preference evidence records the exact values before restart.
Both apps cleared unused worktree trust after target changes and sheet dismissal.
Both apps canceled and confirmed server stop against separate empty fixtures.
Cancel preserved each server. Confirmation stopped only the displayed target. Original lab servers remained responsive.
Evidence: `theme43-trust-stop-checks.json`, `theme43-mac-saved-preferences.json`, and `theme43-phone-saved-preferences.json`.

## Candidate46 identifier entry

Phone Agent ID entry changed typed `codex` to `Codex`. That value could hide matching agents.
Candidate46 disables automatic capitalization and correction for plugin sources, references, agent IDs, tokens, rule values, and colors.
The phone test build and all 374 tests passed. Later candidate46 UI checks verified exact typed identifier entry.
Two added tests check foreign-machine requests and same-pane data isolation after a machine change.
The initial supplementary test build found two test-source typing errors. Candidate46 corrects those errors.
The candidate46 Mac build required a clean compiler cache before compilation succeeded.
Its full suite passed 877 tests with six skips and zero failures.
Both new machine-isolation tests passed in their respective platform suites.
The signed Mac app and phone app are installed under the existing isolated bundle identities.
Restart preserved red Mac metadata, yellow Mac Codex labels, blue phone metadata, and the Mac sidebar width of 248.
Missing score values remained absent on unrelated workspaces.
All 411 frozen source files match the working tree.
Evidence: `candidate46-checks.json`, `candidate46-source-manifest.json`, and `candidate46-mac-install.json` in the lab root.
Targeted preference reads confirmed theme, appearance, and border persistence on both platforms.
Decoded theme values match the pre-restart snapshots exactly.
Evidence: `theme46-persistence-checks.json` records values and exact commands without reading pairing data.

## Candidate46 prompt delivery and phone sharing

Both apps submitted one multiline prompt while an owned proxy dropped the successful server response.
Both displayed the uncertain-delivery warning, retained the draft, disabled submission, and required explicit review before another submission.
The recorder received each displayed prompt exactly once. Counts stayed unchanged after both editors closed.
The proxy stopped and restored the original socket inode. Existing servers remained running.
Evidence: `prompt46-uncertain-results.json` and `prompt45-fault-events.jsonl` in the lab root.

Phone Share opened Save to Files and saved the capture under On My iPhone.
The saved file contains all 400 numbered rows, in order, with 15,109 bytes.
Its size and content fingerprint match the displayed immutable capture.
Evidence: `history46-phone-share.json` and `history46-phone-shared.txt` in the lab root.

Three phone history reads returned identical captures.
RSS changed from 290,224 KiB before capture to 294,864 KiB after one capture and 286,368 KiB after three.
These samples do not establish a performance improvement or a long-run memory bound.
Evidence: `history46-memory-comparison.json` in the lab root.

The same Mac history capture returned `selection_unavailable` after shared-tab size changes.
Read-only probes traced the failure to differences between projected columns and actual terminal width.
Candidate48 uses native `pane.copy_motion` with `motion: line_end` to obtain the exact final column.
It validates pane, row, revision, and column before reading the selection.
Regression tests cover both viewport widths and stale or invalid motion responses. Direct app retests remain pending.

## Candidate46 remaining feature checks

Both apps completed machine management, disconnected-row handling, and reconnect checks. The disposable profile's remote session survived removal.
Phone metadata passed competing-rule order, style removal, agent overrides, and exact identifier entry.
Phone approved GitHub installation and removal matched the reviewed commit and source hashes.
Evidence: `machines46-ui-checks.json`, `/tmp/rai-metadata46-phone-saved.json`, and `/tmp/rai-phone-install46-installed.json`.

Two Mac windows, two simulators, and a terminal client preserved independent pane selection and content.
Shared-tab sizing, separate-tab resizing, rotation, suspension, and recovery passed the recorded checks.
A native Herdr probe reproduced wrong automatic window titles after resizing. The protocol cannot distinguish automatic and explicit titles.
A corrective focus request could reverse newer navigation. Rai preserves explicit title handling and records this upstream limitation.
See [simultaneous client validation](herdr-09-multiclient-validation.md) for source references and regression evidence.

Both apps recovered from forced native transport failure. Recovered histories were empty; each received one fresh notification.
The test restored the original native socket inode. Standard XXXL metadata controls remained readable; the test restored text size.
Evidence: `notify47-ui-results.json` and `notify47-relay-events.jsonl` in the lab root.
Recovery31 separately verified phone WebSocket recovery after an isolated Mac restart.
It verified new identities, selected-pane input, and suppression of closed views.
Recovery31 did not measure notification counts. Audible notification output remains unverified.

## Candidate48 closeout checkpoint

Candidate48 installed under the existing isolated Mac bundle and both owned simulator bundles.
The source audit matched all 411 frozen files. The working tree passed `git diff --check`.
Evidence: `candidate48-checkpoint.json`, `candidate48-mac-install.json`, and `candidate48-ios-install.json` in the lab root.

The Mac setup form displayed all fields, its explanation, and both buttons without clipping.
Cancel preserved the machine list.
Three Mac history reloads each returned all 400 rows and the exact final prompt.
Each capture contained 15,109 characters and matched the previously shared phone file.
The primary phone captured the same text. Mac and phone viewports had different widths; both retained the exact final prompt.
Evidence: `machines48-ui-checks.json` and `history48-width-boundary.json`.

Mac RSS measured 136,480 KiB before the series, 144,240 KiB after one reload, and 133,680 KiB after three.
The baseline followed an earlier capture. These samples do not establish a cold-start bound or a long-run leak result.

Separate fixtures now cover blocked-agent rejection and terminal exit during prompt submission.
The API exit probe received prompt text, then exited before Enter. It returned `agent_prompt_failed`.
These fixture checks do not replace app UI checks. The UI cases remain pending.

## Candidate48 additional interface results

Both apps rejected the blocked-agent prompt and retained their drafts without an uncertain-delivery warning.
The Mac also handled terminal exit during submission. It retained the draft and disabled resubmission.
Closing and reopening the Mac view produced no replay. The separate recorder retained one payload without Enter.
The accepted recorder retained five unchanged records. The verified blocked fixture was removed.
The phone exit fixture remains ready. Evidence: `prompt48-ui-results.json`.

Mac Share → Copy completed through the native share menu.
Pasting into history search returned all 15,109 characters and matched the capture exactly.
The copy contained all 400 numbered rows. The search was cleared afterward.
No external share destination was used. Evidence: `history48-mac-share.json`.

Mac theme import mapped `pane_borders = false` to Off and `true` to Always.
Saving changed the visible frame. The final theme, appearance, and border preferences match their original values.
Evidence: `border48-mac-legacy-import.json`.

Simulator accessibility reads and actions work. Coordinate clicks currently return `noWindowsAvailable`.
The connection menu lacks a usable accessibility target in this automation view, so remaining phone checks need pointer recovery.
No capability or subscription relay remains active. The original commands22 RPC socket inode is restored.

## Candidate49 through Candidate56 validation

The phone exit test retained the prompt draft and disabled submission after the terminal exited.
The reopened view omitted the exited pane. Its recorder contained one bracketed payload without Enter or replay.
Evidence: `prompt49-phone-exit-results.json` in the lab root.

Both apps disabled Split, New Tab, and Create Worktree when the native server omitted those capabilities.
Navigation and all 400 history rows remained available. The relay recorded zero forbidden requests.
The Mac test entered a valid branch. The phone test did not verify branch entry.
Evidence: `capability51-ui-results.json`.

Both apps opened owned worktrees while another view retained its selected pane.
Each app then removed its background worktree without Force. Both views retained their selected panes.
Backend reads confirmed removal. The original three worktrees and accepted prompt recorder remained unchanged.
Evidence: `e14-ui52-results.json`.

Both apps rejected captured plugin links after the terminal content changed.
The native gate forwarded the changed surface before the original activation request.
The plugin recorder retained four events. Neither rejected activation opened a browser.
Evidence: `e20-gate-mac-watch.json`, `e20-gate-phone-watch.json`, and `e20-gate-events.jsonl`.

The initial-subscription fixture delivered creation before the unchanged initial snapshot.
Both root views displayed the new workspace. Later rename delivery exposed a protocol-version filter defect.
Candidate53 subscribes to rename events on protocol 14 and later. Reorder events still require protocol 19.
The fixed live rename check remains pending. Startup reads alone do not establish event delivery.

Candidate53 passed 904 Mac tests with seven gated skips and zero failures.
Candidate54 passed 15 focused Mac theme tests and iOS build-for-testing.
Its iOS editor disables text transformations that previously changed TOML keys and quotes.
Candidate55 confirmed exact typed TOML and editor traits, but two test-state update assertions failed.
Candidate56 changes only the test host. Its full iOS validation remains pending.

The isolated Candidate54 Mac app stopped responding twice. Restart restored its UI and bridge after the first occurrence.
The second sample showed an idle main thread, unlike the first sample's encoding stack.
The cause remains unproven. These results do not establish release stability.
Evidence: `candidate54-restart-results.json` and `candidate54-recurrence.sample`.

## Candidate58 and Candidate59 results

Candidate58 prevents App Nap while its companion listener runs. The activity permits idle display and system sleep.
Listener failure, cancellation, and explicit stop release the activity. Regression tests passed.
Two background bridge checks returned HTTP 101 without activation or restart, thirty seconds apart.
Evidence: `candidate58-background-host-check.json`.

Native clipboard writes now report failure and retain selection. Both platforms passed focused clipboard tests.
The phone history interface also passed an injected first-copy failure and explicit retry.
The failure notice appeared while selection handles remained visible. Retry cleared the notice and copied exactly `SCROLL38`.
Evidence: `clipboard58-phone-history-ui.json`. Mac interface failure validation remains pending.

Phone theme import mapped false to Off and true to Always. Saved preferences and menu selections matched both values.
Line-by-line typing preserved TOML keys and quotes. The test restored all original theme, appearance, and border preferences.
Evidence: `border56-phone-ui-results.json` and `border56-phone-restored-preferences.json`.

Live workspace rename updated both root views without reopening or manual refresh.
Workspace closure then exposed a missing event subscription. Both roots retained the removed workspace.
Evidence: `subscription58-ui-results.json`. The removed `wH` fixture must not be reused.

Candidate58's Option test exposed SwiftTerm's default Meta-key behavior. Candidate59 assigns composition to AppKit.
The installed Mac retest sent no bytes for the first dead key. It then sent `MAC59-éü-END` exactly once.
Evidence: `e17-candidate59-composition-results.json`.

The pixel mouse test produced cell coordinates despite mode 1016. Its correction requires a separate candidate and interface retest.
Evidence: `e17-candidate58-pixel-results.json`.

Candidate58 passed 911 Mac tests, with seven gated skips, and 386 iOS tests. Neither suite reported failures.
Candidate59 passed the same Mac suite and four focused keyboard tests. Its iOS source matches Candidate58.
Scoped reviews through Candidate59 reported no actionable findings. These results do not establish completed release validation.
