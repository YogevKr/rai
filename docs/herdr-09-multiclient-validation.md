# Simultaneous client validation

Candidate46 ran two independent Mac windows, two paired simulators, and one Herdr terminal client together.
All clients used the owned `commands22` server.
The second simulator used a separate app data container and its own pairing credential.

## Result

Pane selection and content stayed independent across the five clients.
Resizing one Mac view changed only its selected tab size.
Both phones passed rotation, background, resume, and shared-tab input checks.
Repeated measurements found no resize loop during the recorded intervals.

E04 remains incomplete because Mac window titles can identify the wrong workspace after resizing.
The terminal content and checked pane remain correct during that failure.
E05 passed the recorded checks, subject to the sampling limits below.

## Independent views

| Client | Initial pane | Changed pane |
| --- | --- | --- |
| Mac `independent-AppWindow-2` | `w3:p1` | `w2:p1` |
| Mac `independent-AppWindow-3` | `wE:p1` | `w6:p2` |
| Primary phone | `w1:p1` | `w3:p1` |
| Second phone | `w1:p6` | `w1:p1` |
| Terminal client | `w5:p2` | `w5:p3` |

CUA selected app panes and inspected their checked rows and rendered shell paths.
The owned terminal client changed tabs through its prefix keys.
Later app observations retained the selected pane contents.
Native CLI focus alone did not establish independent app selection.

## Separate tab sizing

Sizes use rows followed by columns.
The check ran `stty size` in owned shell panes.

| Client pane | Before Mac resize | After Mac resize |
| --- | --- | --- |
| First Mac, `w2:p1` | 48 × 115 | 48 × 115 |
| Second Mac, `w6:p2` | 48 × 115 | 56 × 59 |
| Primary phone, `w3:p1` | 44 × 51 | 44 × 51 |
| Second phone, `w1:p1` | 43 × 51 | 43 × 51 |
| Terminal client, `w5:p3` | 23 × 53 | 23 × 53 |

One initial `pane run` measurement encoded bracketed-paste markers literally in `w1:p1`.
Direct `send-text` followed by Enter measured that pane correctly.
This check does not attribute that CLI fixture failure to Rai.

## Shared tab and phone lifecycle

The second Mac and primary phone shared `w3:p1`.
Mac input established 56 × 59.
The phone rotated while observing, and eight samples retained 56 × 59.
Phone input then established 17 × 96, which four samples retained.

The second phone then joined the same pane.
Mac input restored 56 × 59.
Second-phone rotation left all eight sampled sizes stable.
Second-phone input established 16 × 96, which four samples retained.
The different phone heights reflect the visible keyboard accessory state.

Each phone entered Home through Simulator and resumed through its exact app-switcher card.
Both cards identified `com.whetstone.rai.ios.lab.e2e-56b425104c06`.
Both phones recovered the same pane and current terminal output.
The remaining clients retained their selections and usable terminals.
Both simulators returned to upright portrait.
The Mac window returned to its original size.

The eight-sample runs lasted approximately six seconds each.
These checks establish bounded behavior, not a long-duration stress test.
Physical-device touch, keyboard, and APNs checks remain outside this evidence.

## Reproduced title failure

1. Select `w3:p1`, Mac Worktree 37, in `independent-AppWindow-3`.
2. Select Layout Phone41 in the terminal client.
3. Resize the Mac window through Window → Move & Resize.
4. Observe the Mac title become Layout Phone41.
5. Observe the checked row remain `w3:p1` and terminal output remain `text37-mac`.

An earlier occurrence used local `w6:p2` and terminal-client Layout Mac41.
Resizing changed the Mac title to Layout Mac41 while preserving `w6:p2` content.
Terminal-client navigation alone did not change the title during the second reproduction.

`EndpointWindow.swift:206` displays `model.windowTitle`.
`EndpointWindowModel.swift:118` receives titles from `endpoint.windowTitles`.
The native protocol investigation below confirmed that Herdr generated the incorrect title.
Candidate46 stayed frozen, and Rai continues to preserve explicit title events.

## Native protocol limit

A separate owned `title47` server reproduced the failure without Rai or CUA.
Two native endpoints selected separate workspace panes.
Resizing endpoint A delivered endpoint B's title while A's snapshot retained A's pane.
This result identifies an upstream title-generation defect.

The inspected Herdr checkout was `4b5e9bda239a0b6903889062d756424578e94691`.
The running lab binary reports Herdr 0.9.0.
The probe independently verifies the behavior; it does not establish the binary's source commit.

Native source evidence:

- `src/protocol/wire.rs:1373` defines `WindowTitle` with only an optional string.
- `src/server/headless.rs:2225` handles `ClientShellResize` and promotes the resizing client.
- `src/server/headless.rs:1506` renders the configured title through `app.window_title()`.
- `src/server/headless.rs:1516` sends that title to the foreground client.
- `src/app/window_title.rs:48` reads the global active workspace when rendering the title.
- `src/server/headless/client_views.rs:887` restores the requesting client's target before a scoped API request.
- `src/api/schema/common.rs:34` defines `PaneTarget` with only `pane_id`.

Automatic and explicit titles use the same message, without provenance or a projection revision.
Rai cannot classify their ownership from that message without guessing from the title text.

The probe also tested a same-pane focus after resize.
It repaired the automatic title and preserved the explicit `EXPLICIT47` title.
It preserved the other endpoint's selected pane during that sequence.
However, a queued repair reversed later navigation from pane B back to the earlier pane A.
The server accepted an added `expected_projection_revision` field without enforcing it.
The recorded view moved from revision 5 on B to revision 6 on A.

A client can serialize its own requests and reject navigation changes it has already observed.
The protocol cannot condition the repair on the server's current view revision.
That missing condition prevents a repair guarantee when a view update remains in transit.
No repair focus or title-text heuristic was added to Rai.
Explicit title events remain enabled.

The required upstream fix must render automatic titles from the receiving client's workspace and tab.
It must preserve explicit title set and clear behavior.
A future conditional focus API could also support a guarded repair.

The executable native regression is `title47-native-probe.py --expect-fixed` in the owned lab.
It failed on Herdr 0.9.0 with `Resize gave endpoint A endpoint B's title`.
The preceding eight assertions passed, including explicit-title preservation and the stale-focus demonstration.
Results: `title47-native-probe-results.json`.
Failure log: `title47-native-regression.log`.
Only the owned `title47` server was stopped after this check.

## Artifacts

Lab: `/private/tmp/rai09-391wxjtr`.

- `e04-native46-initial.json`
- `e04-e05-candidate46-results.json`
- `e05-native46-separate-before.json`
- `e05-native46-separate-after-resize.json`
- `e05-native46-phone1-landscape.json`
- `e05-native46-phone1-input.json`
- `e05-native46-phone2-landscape.json`
- `e05-native46-phone2-input.json`
- `e05-measure46.py`

The owned terminal client detached successfully after validation.
Both independent Mac windows and both simulators remain available for the title regression check.
