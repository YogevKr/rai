# Testing & end-to-end verification

How to build, run, screenshot, and end-to-end verify rai against a live `herdr`
daemon — without disrupting anyone's running agents.

For Herdr 0.9 work, follow the [isolated app test contract](herdr-0.9-e2e.md).
Every feature requires isolated macOS and iOS app end-to-end results before completion.
The [integrated checkpoint](herdr-09-integrated-validation.md) records combined builds, UI findings, and pending corrections.
The development bundle and named Herdr lab below do not provide complete app data isolation.

## Build & run a dev build

`scripts/bundle.sh` compiles an optimized build and installs `Rai Dev.app` in `/Applications`.
It falls back to `~/Applications` when necessary.
Development builds use `gr.krig.rai.dev`, separate preferences, and a stable signing identity.
They do not replace `Rai.app` or install release updates.

```sh
./scripts/bundle.sh          # arm64 dev build → /Applications/Rai Dev.app
open -a "Rai Dev"
```

Env overrides:

| var | effect |
| --- | --- |
| `RAI_VERSION` | `CFBundleShortVersionString` (default `0.1.0`) |
| `RAI_UNIVERSAL=1` | universal arm64 + x86_64 binary (used by the release workflow) |
| `RAI_APP_DEST` | install into this dir instead of `/Applications` |
| `RAI_BUILD_CHANNEL` | `development` by default; `release` builds `Rai.app` with `gr.krig.rai`. |
| `RAI_SIGN_IDENTITY` | Stable signing identity. Development defaults to `rai-dev-signing`. Release requires an explicit Developer ID Application identity. Missing identities stop the build before installation. |
| `RAI_PAIRING_CODE_FILE` | Test harness only: writes the current pairing code to an owner-only file. Unset in normal use. Pair through `SIMCTL_CHILD_RAI_PAIR_URL="rai://pair?host=localhost&port=<RAI_BRIDGE_PORT>&code=<code>"`. Verify separate app data, credentials, and bridge targets first. A changed `HOME` does not isolate Application Support. Never delete shared `bridge-audit.jsonl` or `hooks.sock` files as test cleanup. |

For a quick loop without bundling, `swift run rai` runs straight from the package.

For development bundles, use an existing stable identity or create a Code Signing certificate in Keychain Access.
Use the name `rai-dev-signing`, or set `RAI_SIGN_IDENTITY` to its full name.
Keep that identity across rebuilds. Never alternate signing identities for one bundle ID.
Release builds verify the publisher requirement used by the updater before installation.
CI stops when the release certificate is unavailable; it never publishes an ad-hoc substitute.

Development and release apps still share Herdr and Rai's existing Application Support files.
Do not run both integrations against the same keyboard during device tests.

## Herdr 0.9 app lab

The lab channel uses a unique bundle identity and refuses incomplete launch configuration.
Prepare a run with a verified Herdr binary:

```sh
python3 scripts/app-lab.py prepare --herdr /path/to/verified/herdr
```

The command prints `root`, `lab_id`, `bundle_id`, and `bridge_port`.
Use those returned values to build and launch:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  RAI_BUILD_CHANNEL=lab RAI_LAB_ID=<lab_id> RAI_APP_DEST=<root>/apps \
  ./scripts/bundle.sh
python3 scripts/app-lab.py launch --root <root> --app '<root>/apps/Rai Lab <lab_id>.app'
```

The lab stores its launch manifest, process IDs, logs, private binary, sockets, and application data under `root`.
The unique bundle identity separates preferences. `RAI_DATA_ROOT` separates app-owned support files and Claude history.
The launcher supplies private Herdr configuration, state, cache, hook routing, shell startup files, and Git configuration.
It also supplies private temporary, Claude, and Codex directories to its child processes.
Before starting Herdr, the launcher runs the app's `--validate-lab` check against the complete launch environment.
Lab apps skip legacy APNs key migration, Bonjour advertisement, and automatic Tailscale Serve changes.
Native Claude and Codex integration controls use their supported directory overrides.
Other native integrations require a disposable test account. The lab blocks those controls until their targets can be isolated.
Lab hook previews and writes reject settings or script paths outside the lab, including paths through symbolic links.
The lab blocks SSH discovery, session listing, and tunnels until a disposable SSH account and configuration are available.
An owned `.rai-lab-ssh.json` fixture enables only its declared SSH aliases and loopback endpoint.
Set `RAI_MACHINE_E2E_ROOT` to that lab root when running `MachineTransportTests`.
These tests require live detached Herdr sessions and validate distinct machines with duplicate pane identifiers.
Keep physical notification tests separate, using dedicated test credentials and registrations.

The launcher refuses existing process records. Inspect recorded processes before reusing a run.
Stop only processes whose executable and ownership marker match that run. Preserve logs before cleanup.

Use a dedicated simulator for the phone lab. Build with a separate `PRODUCT_BUNDLE_IDENTIFIER`.
Simulator pairing requires signing: pass `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-` to the simulator build.
An unsigned simulator app can fail Keychain writes with error `-34018`.
Keep the test bundle identifier separate from `com.whetstone.rai.ios`.

The lab launcher establishes test targets. It does not count as a feature end-to-end pass.
Follow the [feature scenarios and evidence rules](herdr-0.9-e2e.md) for app UI validation.

### Missing Herdr on a new Mac

Create the negative-test lab with `python3 scripts/app-lab.py prepare --without-herdr`.
Build and launch its app with the same lab commands above.
This manifest permits an absent private executable and does not start a server.
All path, identity, and port checks still apply.
The launcher verifies that the app owns its bridge listener before reporting success.
Servers that Rai starts after Retry receive `herdr-<pid>.json` ownership records inside the lab.
Use these records, the ownership marker, and the live executable path before stopping a test server.

Verify the installation screen appears without a connection spinner or repeated error alerts.
Select Retry before installation and confirm the screen remains usable.
Copy the verified Herdr binary to this lab's `bin/herdr` and grant owner execute permission.
Select Retry again without restarting Rai. Verify the default server starts and a workspace opens.
Pair the isolated phone and verify the missing-server diagnosis clears after recovery.
Keep UI evidence for both platforms. Unit tests alone do not complete this scenario.

Run regression tests with `swift test --filter HerdrInstallationTests` using the Xcode developer directory.

## Machine groups

Use separate local and SSH Herdr servers under one owned app lab.
Keep both servers separate from daily sessions.

Verify these actions through the Mac app:

- Create two spaces on the selected machine. Each action must create one tab and one pane.
- Rename spaces and move tabs between spaces on the same machine.
- Split a remote tab, enter text, and close it with Command-W.
- Close the last space through its context menu. The server must remain empty.
- Use Next Space and Previous Space across machine groups.
- Collapse a machine without changing selection. Keyboard navigation must reveal its destination.
- Interrupt only the owned SSH transport while Local remains selected.
- Confirm automatic recovery preserves selection and terminal identities.
- Quit and restart Rai. Both servers must retain their resources.

Use API snapshots after each action. Check both servers to detect incorrect routing.
Run `swift test --filter MachineNavigation` for navigation regressions.
Set `RAI_NAVIGATION_E2E_TARGET` to the owned SSH alias for the live transport test.
Supply the lab manifest environment. The remote fixture must start empty.
The test covers repeated creation, reviewed closure, Command-W closure, and recreation.

The October 8, 2026 lab uses `/private/tmp/rai09-abbpf77s` and Herdr 0.9.3.
The SSH fixture uses loopback. This check does not measure cloud network latency.
The final Mac suite passed 1,073 tests, with 16 skipped and no failures.
An earlier run had two deadline failures. The full retry passed without code changes after compilation finished.
Evidence: `mac-final-tests.log` and `mac-final-retry.log` in the lab directory.
UI checks passed creation, rename, tab movement, split input, keyboard navigation, collapse, SSH recovery, and app restart.
The reviewed closure check found a replacement-shell defect.
Rai now prepares closure before it publishes the first space and closes through the API with boot identity checks.
The SSH regression passed after the fix. It covered both closure paths and recreation in 9.243 seconds.
Evidence: `native-ssh-reviewed-close-final.log` in the lab directory.
The final signed app also passed context-menu closure. Its remote server remained empty, and Local stayed unchanged.
Evidence: `final-ui-create.json`, `final-ui-reviewed-close.json`, and `final-app-build.json` in the lab directory.

The isolated iOS app built and displayed Local Code through the Mac bridge.
Phone input produced `RAI_IOS_MACHINE_OK` in the correct server pane.
After the final Mac restart, phone input produced `RAI_IOS_RECOVERY_OK` only in Local.
The Mac kept Remote Tests selected. Evidence: `ios-final-input.json` in the lab directory.
Seventeen iOS machine and management tests passed with no failures.
Evidence: `ios-local-input.json` and `ios-machine-tests.log` in the lab directory.
This check covers bridge compatibility. It does not establish physical-device or remote-phone navigation coverage.
The machine-group interface changes macOS only.

## Creating spaces on an empty instance

Use an owned SSH fixture with no workspaces, tabs, or panes.
Read its API snapshot before opening any endpoint connection.
Select that machine in Rai, then invoke New Space once.
The API and sidebar must each show one space with one shell tab.
Repeat the action. Both must show two spaces, with one tab in each space.
The first terminal ID must stay unchanged.
Repeat after closing every space and reconnecting.

Herdr 0.9 creates a default workspace when an endpoint connects to an empty server.
This also applies to inactive metadata endpoints.
Rai must send `workspace.create` through the API before connecting the display.
Creation must not retry after an uncertain response.
Existing-resource mutations retain their boot identity validation.

Run `HerdrWorkspaceCreationTransportTests` for success, lost replies, and malformed replies.
Run `MachineTransportTests.testEmptySSHInstanceCreatesExactlyOneSpacePerRequest` with these variables:

- `RAI_DATA_ROOT` and `RAI_MACHINE_E2E_ROOT`: the owned lab root.
- `RAI_EMPTY_MACHINE_E2E_TARGET`: an allowed alias for a dedicated empty instance.
- The complete environment from that lab's `lab.json`.

The test creates two spaces through SSH and activates a display surface.
It closes both spaces, checks that the instance stays empty, then creates and closes one more space.
It refuses a populated fixture.

Before closing the final remote space, Rai deactivates its display surface and cancels pending title reads.
Herdr otherwise creates a replacement workspace for an active surface or a new metadata connection.
If closure fails, Rai activates the display surface again only after confirming that the source space still exists.

The October 7, 2026 isolated SSH check passed with Herdr 0.9.3 and the 0.1.91 candidate.
The app created one space per request and preserved the first terminal during the second request.
Command-W closed both source spaces. The final closure left zero workspaces, tabs, and panes after five seconds.
A subsequent New Space request created one space and one shell.
Evidence resides under `/private/tmp/rai09-6eef_bvl`, including `final-ui-first.json`, `final-ui-closed.json`, and `final-ui-recreate.json`.
The full Mac suite passed 1,064 tests, with 15 skipped and no failures.
The live SSH regression passed separately. The bundle isolation suite passed 16 tests.

## Closing remote tabs

Use an isolated Herdr server through an owned SSH fixture.
Start a process in a remote tab and record its process ID and terminal ID.
Keep another remote tab and a local tab open.
Select the process tab in Rai and press Command-W.
The tab must disappear from Rai and Herdr. Its process must stop.
Right-click a remote tab and choose Close Tab. It must close in Herdr too.
The other remote tab and local tab must remain unchanged.
Close the actual last tab. Its source space must also disappear.

Use Remove from Rai view to hide a tab while its source process continues.
Refresh machine metadata and restart Rai. The removed tab must stay hidden.
With a hidden sibling and one visible tab, press Command-W on the visible tab.
Only that source tab must close. The hidden sibling must remain on Herdr.
Also remove an unselected tab through its context menu before opening it.

Dismissals belong to a machine, workspace, tab, and server boot ID.
They survive Rai reconnects and restarts. A different Herdr server boot can expose the source tabs again.
Save failures leave the tab visible and show an error.
Source closure failures also leave the tab visible and permit a retry.

After a successful remote close, Rai hides the tab before the endpoint snapshot arrives.
The tab must stay hidden during that metadata delay and must not reappear after refresh.

Run `RaiMixedCloseTests`, `InstanceCloseRequestTests`, and `RaiMixedViewModelTests` for these regression checks.

## Local and remote tab titles

Run the title checks with the Xcode developer directory:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter 'MachineTitleMonitorTests|SnapshotDisplayTests|InstanceWorkspaceTests|HerdrModelsTests'
```

Use two isolated Herdr servers and an owned loopback SSH fixture for UI checks.
Keep a local tab selected while the remote pane emits a new OSC terminal title.
The remote sidebar label must update without tab selection, terminal takeover, or pane creation.
Repeat with the remote tab selected.
Send a Codex session UUID as the title on both instances. Both labels must show `codex`.
Send useful titles next. Both labels must show the new text.
Rename each tab through Herdr while its terminal stays idle. The sidebar must show each custom name.
Send another terminal title. The custom name must remain unchanged.
Reconnect the remote machine and repeat the inactive-tab update.

The title monitor reads metadata after events and combines event bursts into one read.
It retries failed reads at most twice and stops when idle.
Tests check cancellation, retry limits, endpoint identity, pane membership, and custom names.
These checks use terminal fixtures. They do not test an authenticated Codex conversation or the iOS interface.

## Agent startup prompts

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter AgentLaunchReadinessTests
```

Claude's folder-trust prompt means the agent launched and needs input.
Rai accepts a readiness rejection only when the requested pane reports the expected agent as blocked.
The tests cover readiness timeouts, missing state, wrong panes, wrong agents, and actual launch failures.
Rai leaves the startup decision to the user and does not send a replacement launch command.

## Full Disk Access guidance

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter FullDiskAccessGuidanceTests
```

The tests check actual file access errors, wrapped errors, and unrelated failures. No startup action requests this guidance.
They never read protected files or change macOS permissions.

For a manual check, launch the isolated lab bundle with fresh preferences.
Verify that startup, installation, new windows, and restarts show no Full Disk Access dialog.
Trigger a denied configuration or hook-settings operation. Verify that its error offers **File Access Help…**.
Successful operations and unrelated errors must not offer this button. Select the button to open the guide.
Verify that the Full Disk Access dialog explains its optional scope and offers **Open System Settings** and **Not Now**.
Check light and dark appearance in a bundle containing `Rai.icns`. The sheet must show Rai’s icon without a separate Dock item.
Dismiss it, open another window, and restart. The dialog must remain closed.
Open **Settings → Herdr Server → Mac Privacy → Review Full Disk Access…** to show it again.
Verify that **Open System Settings** opens Privacy & Security → Full Disk Access, without changing any grant.
Granting access remains a separate user action in macOS. Follow its quit-and-reopen request when testing a grant.

## Sidebar spacing check

Expanded local spaces include an 18-point target after their final tab for drag-and-drop.
Remote spaces reserve the same height and use the same 2-point row spacing.
Collapsed remote spaces omit that footer, as local spaces do.
The October 5 isolated lab check compared two local spaces and two remote spaces with one tab each.
All four header positions had equal vertical gaps after the change.
The release configuration build passed. The installed release app was not changed.

## Codex Micro permissions

Grant Input Monitoring separately to `Rai.app` and `Rai Dev.app` when using their keyboard integration.
If a previous development build replaced `Rai.app`, remove its old Input Monitoring entry and add the installed release app.
Quit and reopen that app after granting permission. This repairs the existing certificate mismatch once.

Settings → Codex Micro reports access failures at startup and after reconnection.
Use **Open Input Monitoring** for permission failures, then follow the macOS restart request.
Use **Retry connection** to restart device monitoring without losing bindings or the enabled setting.

```sh
python3 Tests/BuildScripts/test_bundle.py
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter 'MicroStatusTests|CodexMicroTests|AppUpdateTests'
```

The bundle tests use temporary apps and fake build/signing tools. They never replace the installed Rai app.
They verify separate development identity, required signing, publisher rejection, and preservation of the installed release on failure.
The Swift tests verify permission recovery state, saved bindings, and disabled release updates in development builds.

## Unit tests

```sh
swift test
```

Heads-up: the Homebrew Swift toolchain frequently lacks XCTest, so `swift test`
can fail locally with an XCTest/linker error even when the code is fine. In that
case `swift build` is the local compile gate, and CI is the source of truth —
`.github/workflows/ci.yml` runs the full suite on `macos-15` with Xcode 16.x
(pinned because SwiftTerm ships a `.metal` shader that only the Xcode-bundled
Metal toolchain can compile).

## Native Herdr endpoint tests

Run endpoint wire, deadline, cancellation, surface, paste, keyboard, and input identity tests with the Xcode toolchain:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter 'HerdrEndpointTests|HerdrScrollTransportTests|EndpointKeyboardTests|EndpointBridgeHostTests|EndpointLinkTests'
```

These tests use temporary Unix socket fixtures. They do not control the installed Herdr server.
Set `RAI_ENDPOINT_TEST_ROOT` to an owned app lab to include the live native handshake and surface check.
The live test verifies the lab ownership marker before connecting.

Additional Mac windows and the phone Workspace View use native endpoint transport.
Test history page controls, live-output recovery, and scrollbar expiry without terminal geometry changes.
Select Light, Dark, and System after each explicit mode. Change the simulator appearance while Workspace View remains open.
Verify Always and Auto with one and two panes. Compare pane reads before and after border changes.
Set different appearance and border choices in two Mac windows. Verify each existing window retains its choices.
Restart the isolated app, open another window, and verify the last saved choices become its defaults.
Restart the isolated Mac host while Workspace View remains open. Verify automatic recovery and input with new view identity.
Background and restore the phone app. Close Workspace View, restart the host, and verify no new endpoint opens.
Test image replacement beside another image, clipped history recovery, rotation, deletion, and image inspection.
The Mac and phone share image cache and SwiftTerm replacement regression tests.
Test configured commands with captured targets. Reload configuration while the command list remains open and verify stale-command rejection.
Test release notes on both platforms. Verify popup input reaches only the active popup terminal.
Views of one Herdr pane share history position. Validate touch gestures separately from menu actions.
The primary Mac window and phone observation view retain their previous terminal paths.
Phone endpoint tests cover request identity, sizing, navigation, queue limits, failed writes, and closure races.
Phone text tests cover stable capture, implicit links, OSC 8 links, and rejected remote file paths.
Verify touch selection, Copy, and browser navigation in both phone terminal views.
During output, capture text and confirm later output cannot change the capture or selected text.
Test tab creation, splits, directional focus, paste boundaries, application cursor keys, Kitty keys, reconnect, and window closure.
Use separate app windows and record each input marker's target pane.
Record app hashes and pane snapshots before removing temporary test panes.
Full unit gates do not replace the isolated app scenarios in `herdr-0.9-e2e.md`.

## iOS connections and terminal retention

### Codex touch scroll check

The `rai-ios-scroll-e2e` scheme checks touch input in an authenticated Codex conversation.
It uses XCUITest swipes and reads numbered lines from screenshots.
The two-swipe test requires at least five lines of movement in each direction.
The repeated-swipe test must reach line 5 or earlier, then return to its initial position.
The test saves screenshots and line numbers in the result bundle.
It skips bundles outside `com.whetstone.rai.ios.lab.*` before opening an app.

Use an isolated Mac lab and a paired simulator. Keep the regular Herdr instance separate.
Build and install the candidate before testing. The test activates the installed app and preserves its open conversation.

```sh
xcodegen generate --spec ios/project.yml
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build-for-testing \
  -project ios/rai-ios.xcodeproj -scheme rai-ios-scroll-e2e \
  -destination 'platform=iOS Simulator,id=<simulator-id>' \
  -derivedDataPath /tmp/rai-ios-touch-e2e \
  RAI_IOS_BUNDLE_IDENTIFIER=com.whetstone.rai.ios.lab.scroll \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun simctl install \
  <simulator-id> /tmp/rai-ios-touch-e2e/Build/Products/Debug-iphonesimulator/rai.app
```

Launch the installed lab app. Pair it with the isolated Mac bridge if required.
Use the same Codex version and transcript mode as the reported failure.
Codex 0.160.0 enables fullscreen history with `-c tui.fullscreen_transcript=true`.
That version ignores the deprecated `features.transcript_v2` flag.
Start a fresh conversation in its isolated Codex pane. Request `1. Line 1` through `100. Line 100`.
Then request `101. Line 101` through `200. Line 200` for the keyboard and reopening tests.
Do not reuse a conversation containing repeated fixture numbers. Those numbers make OCR movement checks ambiguous.
Open that pane on the phone. Start near the end with the keyboard hidden.
Then run:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test-without-building \
  -project ios/rai-ios.xcodeproj -scheme rai-ios-scroll-e2e \
  -destination 'platform=iOS Simulator,id=<simulator-id>' \
  -derivedDataPath /tmp/rai-ios-touch-e2e \
  -resultBundlePath /tmp/rai-ios-touch-result.xcresult \
  RAI_IOS_BUNDLE_IDENTIFIER=com.whetstone.rai.ios.lab.scroll \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
```

This check verifies the visible conversation with touch input.
It does not verify a physical iPhone, active output, horizontal movement, or every alternate-screen application.

The October 5, 2026 check passed on `rai-ios-test`, running iOS 26.0.
The first visible lines moved from 68 to 51, then returned to 68.
The installed app matched the candidate binary before the test.
The original gesture delegate passed. The proposed delegate removal had no demonstrated benefit and was reverted.
Evidence: `/tmp/rai-ios-touch-recovery.xcresult` and `/tmp/rai-ios-touch-recovery-attachments`.
The related model, history, and cache suites passed all 44 tests.
Evidence: `/tmp/rai-ios-scroll-related.xcresult`.

Those earlier Codex checks used version 0.153.4. They do not validate the reported fullscreen mode.
A later check used Codex 0.160.0 with `tui.fullscreen_transcript=true`.
Repeated touch swipes moved through first visible lines `[72, 24, 3, 24, 72]`.
Evidence: `/tmp/rai-ios-codex-0160-history-before.xcresult` and its exported attachments.
This check covered one response. It did not establish a fix for the user's iPhone failure.

The second-message check stopped during an XCTest idle wait so the user could test manually.
It has no passing result: `/tmp/rai-ios-codex-0160-messages-before.log`.
The user reported a simulator limit at line 124, then reported working scrolling after both lab apps restarted.
The restart preserved the same binaries, Codex process, and conversation. No scrolling code changed.
The cause remains unknown. Test keyboard changes and reconnection before treating the failure as resolved.

The follow-up test adds keyboard-open, keyboard-hidden, and pane-reopening checks.
Keep gesture starts inside the transcript. Codex can ignore wheel input over its composer or footer.
The first attempt stopped when the simulator screenshot service timed out. Restarting only the test device restored screenshots.
The next attempt began upward gestures over Codex's footer. Moving them into the transcript corrected that test error.
An older response repeated lines 1–20 in the first fixture. Screenshots confirmed movement despite an unchanged OCR number.
Use a fresh conversation to remove that ambiguity.
The reopening check passed across two numbered responses: `[174, 147, 120, 101, 74, 47, 20, 1, 20, 47, 74, 101, 120, 147, 174]`.
Evidence: `/tmp/rai-ios-keyboard-reopen-in-transcript.xcresult` and its exported attachments.

The user's iPhone runs build 48, released from `b5128aa55f1394150d747a2ac94bf552bdfc3388`.
[Release run 37131978366](https://github.com/YogevKr/rai/actions/runs/37131978366) set that build number and completed its upload.
CI overrides the source build number. The simulator's build 38 label alone does not establish different scroll code.
Both used the same pane gesture code and SwiftTerm revision `97d70b00211de945f7e83581b4f1c49c8ab9e0de` before this fix.

The fresh two-response fixture reproduced a keyboard-open limit at line 8, which OCR reported as line 9.
The Mac pane still contained line 1. The phone cropped the top of the pinned Mac grid to keep the cursor visible.
Every swipe went to Codex, so the phone could not reveal those cropped rows after Codex reached its oldest message.
Evidence: `/tmp/rai-ios-keyboard-crop-before.xcresult` and the matching isolated pane read.
The gesture now yields to native scrolling while rows remain cropped in that direction.
At the viewport boundary, wheel input continues through the existing Codex route.
The lower boundary uses the cursor position, matching SwiftTerm's follow behavior.
Using the geometric bottom would consume another native pan for the footer after every Codex frame.
The UI test permits unchanged line numbers when a pan reveals only part of a row or the footer.
It still requires reaching line 5 or earlier, returning to the starting line, and retaining the open keyboard.

The October 6 check passed all four touch tests on the isolated iPhone 17 Pro simulator, running iOS 26.0.1.
With the keyboard open, the first visible line moved from 189 to 1, then returned to 191.
With the keyboard hidden, it moved from 173 to 1, then returned to 173.
Pane reopening and repeated scrolling also passed.
Evidence: `/tmp/rai-ios-codex-crop-full.xcresult` and `/tmp/rai-ios-codex-crop-full-attachments`.
The full iOS unit suite passed all 421 tests, including cropped-grid gesture routing.
Evidence: `/tmp/rai-ios-crop-unit-full.xcresult`.
The candidate remains installed only in the isolated simulator. A physical iPhone check and TestFlight upload remain outstanding.
These results establish the keyboard cropping fix. They do not explain the earlier restart-dependent limit or the Mac memory report.

Release preparation copied only this iOS fix, its tests, and its documentation into an isolated worktree.
The review identified an accessibility position risk and a stopped-app test launch issue.
Accessibility paging retains its existing wheel route. The test now calls `launch()` when the app is stopped.
The final review found no actionable defects.
The release copy passed all 421 unit tests and all four touch tests after those corrections.
Evidence: `/tmp/rai-ios-release49-unit-final.xcresult`, `/tmp/rai-ios-release49-touch-final.xcresult`, and `/tmp/rai-ios-release49-review-final.json`.
Release commit: `0b2e6d885b90d8ce61bc099940cf9fb048f31a55` on `fix/ios-keyboard-scroll`.
The TestFlight workflow for build 49 is [run 37378154729](https://github.com/YogevKr/rai/actions/runs/37378154729).
That run passed all 421 iOS tests and uploaded build 49 successfully.
[Status run 37379667401](https://github.com/YogevKr/rai/actions/runs/37379667401) confirmed Apple's `VALID` processing state.
Internal distribution is `IN_BETA_TESTING`; external distribution is `READY_FOR_BETA_SUBMISSION`.
Build 49 is available for internal testing. Physical iPhone validation remains outstanding.

The same session exposed a separate Mac lab memory problem.
The user's screenshot showed 23.16 GB for `Rai Lab e2e-8d996bccaf92`.
That process exited before allocation diagnostics could run.
A monitored five-minute restart stayed below 150 MiB resident memory, including the iPhone settings screen.
This short run did not identify the cause. The monitor stopped the lab app after the run.
The memory problem remains unresolved. No release followed this check.

A later load check used allocation graphs and a 512 MiB physical-footprint limit.
This measurement includes compressed memory. Resident memory alone cannot match Activity Monitor's total.
The test exercised continuous colored output, a paused phone process, reconnection, and the visible pairing screen.
The guarded run peaked near 401 MiB and ended near 173 MiB after 328 seconds.
The allocation scan found 21,664 unreachable heap bytes. This finding does not explain the reported 23.16 GB.
The temporary `memory-load` workspace and output script were removed. The lab app stopped after the test.
The existing isolated Herdr sessions remained intact.
Evidence: `/tmp/rai-memory-20261005/summary.json`, `footprint.jsonl`, and the allocation graphs in that directory.
These tests did not reproduce the memory problem. The original process had run for about four hours.

The user reported no manual interaction before the memory spike.
A later idle trace ran for 747 seconds with Codex visible and the phone socket connected.
After 90 seconds, physical footprint stayed between 137.27 and 140.05 MiB.
Allocation captures came from the same process. Their difference did not establish a leak.
Evidence: `/tmp/rai-memory-20261005/idle/summary.json` and `stable-heap-diff.txt` in that directory.
A separate four-hour idle trace stopped after 680 seconds to test the corrected Codex version.
Its interrupted result is `/tmp/rai-memory-20261005/long-idle/summary.json`.
The next guarded scroll session ran for 2,484 seconds and ended near 149 MiB physical footprint.
Evidence: `/tmp/rai-memory-20261005/transcript-v2/summary.json`.
The manual test now uses `/tmp/rai-memory-20261005/fullscreen-user-test/summary.json`.
Its guard stops only the isolated Mac app after four hours or at 512 MiB physical footprint.

### Connection and retention tests

Generate the iOS project, then run the tests on an isolated simulator:

```sh
xcodegen generate --spec ios/project.yml
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project ios/rai-ios.xcodeproj -scheme rai-ios \
  -destination 'platform=iOS Simulator,id=<simulator-id>' \
  -derivedDataPath /tmp/rai-ios-network-tests test
```

`BridgeNetworkTests` covers stalled authentication, missing pongs, network changes, late errors, and composed-line queue behavior.
`BridgeSocketIntegrationTests` uses a loopback WebSocket server with delayed authentication and a dropped connection.
It checks ping handling, conditional history replies, and raw-key replay prevention.
`ScrollbackRefreshTests` covers traffic pacing, conditional replies, and cancellation when the user leaves a pane.
`TerminalViewCacheTests` covers cached cells, scroll positions, memory limits, context isolation, and nested horizontal offsets.
It checks text positions after history trimming and terminal deallocation after cache removal.
Its SwiftUI navigation test records a screenshot before any reply reaches the restored terminal.
`PromptDetectionTests` rejects cached permission controls until a full screen frame arrives.
`FullFrameRepaintTests` covers full frames that match the retained screen, changed text, attributes, cursor, grid size, and the ignored preview frame.
`ConnectionBannerStateTests` covers the three-second delay, recovery, repeated retries, and immediate pairing repair.
It also checks banner height with a long hostname at normal and accessibility text sizes, and records screenshots.
`BridgeErrorPolicyTests` checks that legacy action errors preserve a healthy connection while missing-herd errors remain visible.
`OfflineResilienceTests` checks that disconnected rows remain stale through authentication until a fresh snapshot arrives.
These tests use synthetic content and do not connect to Herdr or change system network settings.

Run the shared protocol and Mac bridge checks with `swift test`.

Herdr management regression tests cover capability checks, target identity, audit records, and phone failure recovery.
Run `swift test --filter 'HerdrManagementTests|HerdrManagementAppTests|BridgeAudit'` for the focused Mac gate.
The simulator suite includes `HerdrManagementBridgeTests` for stale confirmation, result correlation, socket loss, and audit rejection.
Use an owned lab server for app update and handoff checks. Compare shell and agent process IDs before and after handoff.
See [Herdr 0.9 evidence](herdr-0.9-e2e.md) for current isolated app results and remaining checks.

## Application updates

### Tab order, pane reopen, and scrolling

Run the focused Mac checks with the Xcode developer directory:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'TabMovePlannerTests|CloseTabReopenTests|ClosedTabStoreTests|ClosedPaneStoreTests|SidebarDropRulesTests|TerminalContainerOwnershipTests|TerminalPredictionLifecycleTests'
```

On an isolated iOS simulator, run `FullFrameRepaintTests`, `TerminalViewCacheTests`, and `ScrollbackRefreshTests`.
The mouse-mode test checks that observation frames cannot install a competing pan gesture.

Use disposable tabs and panes in the signed app lab for these interaction checks:

1. Close the middle of three tabs, then press Command-Shift-T. Check that its saved position returns.
2. Close a split pane, then press Command-Shift-P. Check its working directory and agent session, when available.
3. Drag the first tab below the last tab. Check that it stays in the same space.
4. Scroll during terminal output on both platforms. Check that text stays below the Mac pane header.
5. On iOS, open a program that enables mouse tracking. Check history scrolling before and after leaving that program.

Pane reopen creates a right split. It uses another pane in the same space if the original tab is absent.
It creates the space again if no anchor remains. Closing a tab's only pane uses tab reopen.
Unit tests do not replace these interaction checks.

#### Isolated verification, 2026-09-27

Lab evidence: `/private/tmp/rai09-adq9vzbz/e2e-results.json`.
The Mac app used bundle ID `gr.krig.rai.lab.e2e-7fb4721124ff` and a private Herdr socket.
The phone app used bundle ID `gr.krig.rai.scrolltests` on the `RaiScrollTests` simulator.

| Check | Result |
| --- | --- |
| Reopen the middle tab | Passed. The order returned to A, B, C. |
| Reopen a split pane after changing directory | Passed. The pane retained its current directory. |
| Reopen a pane after restarting the Mac app | Passed. The pane returned to its original tab. |
| Mac wheel scrolling during output | Passed in both directions. Terminal text stayed below the headers. |
| iOS accessibility scrolling with terminal mouse tracking | Passed in both directions. Older numbered rows and the tail remained reachable. |
| Server insertion slot for the workspace end | Passed. Slot three produced B, C, A and preserved the next workspace. This does not test dragging. |
| Drag a tab to the workspace end | Unverified. CUA drag produced no drop on new or existing targets. |
| iOS touch scrolling | Unverified. CUA drag produced no scroll. Accessibility scrolling does not test touch recognition. |

The pane test found a stale-directory bug. Pane closure now captures live process information before closing the pane.
Review found an insertion-slot error. End drops now use the workspace tab count, as the server requires.
The latest focused Mac run passed 65 tests. The focused iOS run passed 46 tests.
The final full Mac run passed 954 tests, with seven skipped and zero failures.
The final `autoreview --mode local --engine codex` run found no actionable defects after the insertion-slot correction.
The quality check still reports 39 major findings, including duplication and growth in existing classes.
Full gesture verification requires another UI automation tool or manual testing.
CUA rules require explicit user permission before another UI automation tool can run.

### Close shortcuts

Run these regression checks in a fresh app lab with disposable tabs and panes:

1. Create two tabs. Press Command-W. Confirm that only the selected tab closes and the window stays open.
2. Repeat in an independent window. Confirm that the other window keeps its selected tab.
3. Split a pane in each window type. Press Command-Shift-W. Confirm that only the selected pane closes.
4. Hold each close shortcut. Confirm that one press closes at most one resource.
5. Open Settings and press Command-W. Confirm that Settings closes and the terminal tabs remain open.
6. Open Check for Updates and press Command-W. Confirm that the panel closes and the terminal tabs remain open.
7. Press Command-Option-W in a terminal window. Confirm that the window closes and its Herdr tabs remain available.

Command-W closes the selected tab in terminal windows. Command-Shift-W closes the selected pane.
Command-Option-W closes the window. In auxiliary windows, Command-W closes that window.
The File menu replaces SwiftUI's default Close command to prevent competing Command-W shortcuts.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter 'AppReleaseTests|AppUpdate|AppTerminationTests'
```

These tests cover numeric version order, release assets, skipped versions, retry, duplicate actions, and opaque dialog rendering.
The popup consumes Command-W and Command-Shift-W. Tests check that both shortcuts dismiss it without reaching a terminal.
Manual checks join an active background request and keep their visible result, including skipped releases and errors.
Installation tests use temporary app folders. They check replacement, rollback, retained backups, and signature rejection.
They do not replace `/Applications/Rai.app` or stop Herdr.

Set `RAI_UPDATE_DIALOG_SNAPSHOT` to a PNG path to save the dialog render during `AppUpdateTests`.
The optional signature probe uses the downloaded official 0.1.48 ZIP and its extracted app:

```sh
RAI_UPDATE_ARCHIVE_PROBE=/path/to/Rai-0.1.48-macos.zip \
RAI_UPDATE_APP_PROBE=/path/to/unpacked/Rai.app \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter AppUpdateTests.testOfficialReleaseArchiveAndSignature
```

`rai-updater` runs outside Rai's app process. It verifies the candidate before reporting readiness and again after Rai exits.
It waits up to two minutes for normal shutdown. It never stops the Herdr server.
Rai schedules update shutdown on the main run loop, after the update task returns.
The delegate returns `terminateLater` while asynchronous cleanup runs.
Cleanup completion or its five-second deadline schedules the reply that permits AppKit to finish termination.
This preserves system logout and shutdown requests.
Repeated requests do not restart cleanup. The deadline cancels cleanup without waiting for an unresponsive task.
`AppTerminationTests` checks callback scheduling, repeated requests, and a cleanup operation that never completes.
`AppTerminationProcessTests` launches owned AppKit processes for normal Quit, update Quit, and stalled update cleanup.
Those processes use no Herdr server, network listener, window, or user preferences.
The installed 0.1.91 failure left the verified candidate staged while the old app remained in AppKit termination.
A process sample showed a cleanup worker waiting in `TailscaleServeController.waitForExit`.
The updater's two-minute wait expired before Rai exited.
The installer retains the previous app and reports errors instead of deleting the backup.
`scripts/bundle.sh` includes and signs the helper before signing the outer app.

Release metadata and archive hashes come from the [GitHub Releases API](https://docs.github.com/en/rest/releases/releases).
Signature checks use Apple's [Code Signing Services](https://developer.apple.com/documentation/security/code-signing-services).
Current release archives contain no symbolic links. The installer rejects archives with symbolic links before extraction.

### Machines dialog layout

The Mac dialog keeps search above the list and Refresh, Add Machine, and Done below it.
Machine selection uses plain row buttons. Each compact menu stays beside its connection status.
Rows omit an address when it equals the machine label.
Search filters machine names and addresses. Agent search retains its status filter when available.
Selecting an online machine closes the dialog. Opening its menu keeps the dialog open.
Verify search, empty results, selection, menus, Add Machine, Cancel, Refresh, and Done in the isolated app.
Check the shared view with an iOS simulator build before release.

The October 8 hotfix passed 1,078 Mac tests, with 17 skips and no failures.
The iOS simulator build passed for both supported simulator architectures.
Logs: `/private/tmp/rai-update-layout-full.log` and `/private/tmp/rai-update-ios-build.log`.
The isolated Mac check passed search, empty results, selection, menus, field validation, Refresh, Cancel, and Done.
Normal Quit exited the fixed lab app. The lab server retained the same pane and terminal identifiers.
Evidence: `/private/tmp/rai09-abbpf77s/hotfix-quit-result.json` and its before/after source snapshots.

The [sidebar performance check](sidebar-tab-switch-performance.md) records the local and remote path regression tests.
Its repeated-render fixture reduced median CPU work by 73 percent with the same result checksum.
This measures sidebar computation, not complete tab-switch latency.
The socket line check covers fragmented, coalesced, bounded, buffered, and closed responses.
The 2 MiB unterminated response passed in 0.133 seconds after incremental scanning.
The updater checks the Applications directory for write access. It does not require write access inside the signed app bundle.

## Cached terminal streams

Rai keeps cached terminal clients attached across tab and machine switches.
Visibility changes do not send keys, stop clients, or rebuild SSH tunnels.
Herdr supplies the initial screen. Rai does not send Ctrl-L to request a redraw.
An action rejection does not mark a responding machine offline.

Unvisited panes wait until their first visible layout before attaching.
An early user keystroke starts that attach immediately, without waiting for the layout timer.
Rai sends that keystroke once. It does not queue keys for failed connections.
Closed panes, removed machines, and cache eviction still stop their display clients.
The cache holds between eight and 32 views per machine.
Hidden clients continue receiving terminal frames within the existing output buffer limit.
This costs background traffic; Herdr's native surface-interest protocol avoids that traffic.
Rai's direct terminal clients do not yet support surface-interest control.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test -j 4 --filter 'TerminalVisibilityTests|TerminalPool'
```

The PTY tests check stable client identity, cached scrollback, raw input, retries, and eviction.
A byte recorder checks that attachment and tab switches send only supplied input.

The SSH regression requires the owned loopback lab environment and `RAI_NAVIGATION_E2E_TARGET`.
Run `MachineNavigationTransportTests.testSSHNavigationKeepsConnectionsAndDoesNotInjectInput`.
It creates two temporary spaces and records input while another thread produces output.
It checks client identity, terminal identity, connection state, output, and rejected focus requests.
It closes only its own spaces. Existing lab spaces remain unchanged.
This test does not establish authenticated Codex or cloud coverage.

The October 8 check used Herdr 0.9.3 in two isolated servers and a private loopback SSH fixture.
The full Mac suite completed 1,075 tests with 17 skips and no failures.
The separate SSH regression passed, including the first keystroke before the attach timer.
All 16 build-script tests passed. The signed lab bundle built successfully.

Evidence remains in `/private/tmp/rai09-abbpf77s`:

- `lifecycle-before.log` records the reproduced input and disconnect failures.
- `first-key-before.log` records the reproduced first-keystroke failure.
- `remote-final-suite.log` records the full Mac gate.
- `ssh-initial-input.log` records the final SSH regression.
- `ui-stream-after-switch.json` records unchanged display clients and exact input bytes.
- `ui-stream-recovery.json` records source-process survival across the intentional SSH interruption.
- `ui-first-key-final.json` confirms immediate typing reached the remote shell in the final app.
- `remote-ui-final-created.json` and `remote-ui-final-closed.json` confirm one tab opened and closed at its source.
- `remote-fix-build.json` records the app identity and executable hash.

The isolated Codex profile was signed out. No authenticated Codex task was tested.

## Surface validation and event limits

Endpoint patches must advance the surface revision by one and retain the current boot and projection identity.
Patches cannot change pane rectangles or update a surface with an active popup.
Rai checks cell counts, hyperlink indexes, visible cursor bounds, and pane bounds before it changes the surface.
Duplicate pane updates and invalid patches fail without changing the current surface.

Both legacy event streams retain at most 256 entries per buffer.
The subscription buffer includes its readiness message.
Overflow closes the subscription and returns `HerdrClientError.eventBufferOverflow`.
The app's event loop reconnects and obtains a fresh snapshot after this error.
Callers of `events()` must handle the error; that method does not reconnect itself.

Run the regression tests:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --scratch-path .build-tests --filter 'EndpointSurfacePatchTests|HerdrEventTransportTests'
```

## Equal-work renderer benchmark

Use `--fixed-work` to compare SwiftTerm CoreGraphics and Metal with the same input workload.
The timer runs at 60 Hz. Slow drawing can delay timer callbacks.
This mode completes every warmup and measurement tick, even when elapsed time exceeds `--seconds`.
The measurement includes a final 100 ms interval for pending AppKit updates.
It does not wait for GPU completion or physical screen presentation.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift build -c release --scratch-path .build-tests --product rai-bench
.build-tests/release/rai-bench --fixed-work --seconds 2 --warmup 0.5 --panes 4 --renderer cg
.build-tests/release/rai-bench --fixed-work --seconds 2 --warmup 0.5 --panes 4 --renderer metal
```

Repeat with `--panes 9`. Run each case three times and alternate renderer order.
Compare CPU seconds and elapsed time only when `fedBytes`, `ticks`, and `grids` match.
Timed runs can feed unequal byte counts. Their CPU percentages cannot establish a renderer winner.

Results from 2026-10-05 used an Apple M3 Pro, macOS 26.6.2, Swift 6.2, and a release build.
Each case ran three times with 30 warmup ticks and 120 measurement ticks.
The actual terminal size was 103 columns by 33 rows per pane.
Four-pane runs fed 399,840 bytes. Nine-pane runs fed 399,600 bytes.

| Panes | Renderer | Median CPU seconds | CPU range | Median elapsed seconds |
| --- | --- | ---: | ---: | ---: |
| 4 | CoreGraphics | 1.57 | 1.43–1.61 | 6.01 |
| 4 | Metal | 1.19 | 1.13–1.22 | 4.93 |
| 9 | CoreGraphics | 2.47 | 2.36–2.50 | 6.14 |
| 9 | Metal | 1.74 | 1.67–1.88 | 5.05 |

Metal used 24% less CPU at four panes and 30% less at nine panes for this workload.
[Raw results](terminal-benchmark-2026-10-05.json) retain all commands, counters, and measurements.
These runs compare SwiftTerm renderers. They do not measure Herdr GPUI or the new endpoint validation checks.
They do not establish a speed improvement from the validation or event changes.
The app retains its current renderer setting. Live Mac and iOS endpoint UI checks remain unverified for these changes.

### Production terminal view checks

The renderer probes create visible windows containing Rai's `FocusAwareTerminalView`.
They never connect to Herdr or change installed app preferences.
The renderer override uses a temporary defaults domain. Teardown restores that domain.
Metal probes stage SwiftTerm's shader in the XCTest bundle and remove their copy afterward.
SwiftTerm's shader lookup otherwise misses SwiftPM's resource location under XCTest.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  RAI_TEST_TERMINAL_RENDERER=cg \
  swift test --scratch-path .build-tests --filter TerminalRendererProbeTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  RAI_TEST_TERMINAL_RENDERER=metal \
  swift test --scratch-path .build-tests --filter TerminalRendererProbeTests
```

Both renderers passed four automated probes on 2026-10-05:

| Probe | Checks |
| --- | --- |
| Selection | Output preserves selected text. Copy and local scrollback return the expected text. |
| Search | Search finds text. The search bar stays above Metal and receives pointer events. |
| Window changes | Cursor visibility, resize, hide, and window transfer preserve the expected renderer and terminal state. |
| Images | Paste writes a PNG path. Kitty image data and placement reach the terminal state. |

These assertions check terminal state and view structure. They do not inspect rendered screen pixels.
They do not test Herdr scrollback selection, app menus, or `EndpointTerminalView`.
The current Metal preference applies to attached terminal views. It does not enable Metal for endpoint views.

For manual inspection, add `RAI_RENDERER_PREVIEW_SECONDS=180` and filter to `TerminalRendererProbeTests/testInteractivePreview`.
The preview owns an echo process and closes after the requested interval.
It provides text, colors, Unicode, an image, local scrollback, and a Find menu.
The UI tool could not select the XCTest process during this run. Screen inspection remains unverified.

The signed app lab build stopped because `rai-dev-signing` was unavailable.
`security find-identity -v -p codesigning` returned `0 valid identities found`.
Complete the signed lab checks before making Metal the default. Supply an existing stable identity through `RAI_SIGN_IDENTITY`.

## Typing latency benchmark

The Mac terminal parses queued output in chunks of at most 16 KB.
It returns to the event loop between chunks and paces their display updates.
The PTY reader waits for each read to finish parsing before delivering another read.
This keeps pending transport output within one 128 KB read. Keyboard writes use a separate path.
Small keyboard echoes retain the immediate display path.
Stopping or replacing a terminal releases blocked reads and discards output from the old process.

Run the output and transport regression tests:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter TerminalOutputTests
```

These tests check event-loop progress, byte order, Unicode, synchronized output, cancellation, keyboard delivery, and PTY resizing.

Frame pacing delays display updates, but it does not delay parsing reads of 16 KB or less.
The reader acknowledges these reads immediately. Keyboard echoes can then follow background output without waiting for another frame.
A regression test checks parsing, read acknowledgement, and echo order without advancing the event loop.

Measure the production Rai view and a real, isolated PTY:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  RAI_TYPING_LATENCY_PROBE=1 swift test --filter TypingLatencyProbeTests
```

The probe tests small echoes, 1 KB echoes, and typing during continuous output.
It sends events directly to its own view. It never types into a Herdr pane.
Each scenario records 60 samples after ten warmup keys. Predictive echo stays disabled.
Timing stops at the display-update callback, before physical screen presentation.

Set `RAI_TEST_TERMINAL_RENDERER=cg` or `metal` to compare the production view with an explicit renderer.
This option shows the test window and asserts that the requested renderer activates.
Without this option, the probe keeps its previous window and preference behavior.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  RAI_TYPING_LATENCY_PROBE=1 RAI_TEST_TERMINAL_RENDERER=metal \
  swift test --scratch-path .build-tests --filter TypingLatencyProbeTests
```

On 2026-10-05, both renderers completed three runs on the same Mac used for the CPU benchmark.
These runs used debug builds and one visible production terminal view. Renderer order alternated between pairs.
The table shows the median of each renderer's three run medians.

| Typing workload | CoreGraphics median, ms | Metal median, ms |
| --- | ---: | ---: |
| Short echo | 1.95 | 0.69 |
| 1 KB echo | 82.99 | 82.27 |
| Continuous output | 26.40 | 24.15 |

Continuous-output run medians ranged from 22.96–31.48 ms for CoreGraphics and 23.04–27.88 ms for Metal.
Metal reduced short-echo callback delay. The other workloads do not establish a typing improvement.
These measurements do not establish a change in visible typing delay.
[Raw production-view results](terminal-view-probe-2026-10-05.json) retain commands, test output, and measurements.

On 2026-09-06, the streaming median fell from 108.1 ms to 17.3 ms after removing the read delay.
The streaming p90 fell from 182.6 ms to 23.8 ms. These debug-build results describe this workload only.
Small-echo medians stayed below 1 ms. Large-echo medians stayed near 21 ms.

`rai-bench --latency` hosts one terminal view. It runs 200 samples for each
path. The terminal path sends an `NSEvent` through `TerminalView.keyDown`.
The delegate feeds the sent byte back as its echo. The timer stops in
SwiftTerm's `rangeChanged` display-update callback.

The prediction path starts its timer before the same synthetic key dispatch.
It uses the production `PredictionOverlayView` and stops after its `draw` callback.

Use the app's default CoreGraphics renderer:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift run --scratch-path .build-tests rai-bench --latency --renderer cg
```

Run the baseline without rai's small-feed decision:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift run --scratch-path .build-tests rai-bench --latency --renderer cg \
  --no-fast-path
```

`--no-fast-path` does not bypass `TerminalView` input handling. SwiftTerm still
uses its own recent-input fast path. This matches production before rai's
size guard. Use `--samples N` to change the sample count.

The isolated lab measures the separate herdr attach cost:

```sh
scripts/herdr-lab.sh start
RAI_LAB_SOCKET=$(scripts/herdr-lab.sh socket)
RAI_LAB_TERMINAL=$(HERDR_SOCKET_PATH="$RAI_LAB_SOCKET" herdr api snapshot \
  | jq -r '.result.snapshot.panes[0].terminal_id')
scripts/attach-latency.py "$RAI_LAB_SOCKET" "$RAI_LAB_TERMINAL" 60
scripts/herdr-lab.sh stop
```

Results from 2026-09-03 used a debug build on the same Mac:

| Path | Samples | Baseline median / p90 | Guarded median / p90 |
| --- | ---: | ---: | ---: |
| terminal key to display update | 200 | 0.372 / 0.495 ms | 0.237 / 0.393 ms |
| key to prediction overlay draw | 200 | 0.434 / 0.567 ms | 0.406 / 0.518 ms |

The baseline command used `--no-fast-path`. The guarded command omitted it.
The fast-path flag does not change the prediction path. Its difference is
run noise.

The guarded terminal path cut the median by 0.135 ms, or 36%.
It cut p90 by 0.102 ms, or 21%. The prediction differences are run noise.

The baseline terminal range was 0.163–3.010 ms. The guarded range was
0.150–0.548 ms.

Three fresh isolated-lab runs used 60 samples each:

| Run | Median | p90 |
| --- | ---: | ---: |
| 1 | 20.3 ms | 22.2 ms |
| 2 | 20.1 ms | 25.1 ms |
| 3 | 4.4 ms | 22.3 ms |

The combined range was 0.6–30.5 ms. Most echoes complete below 5 ms.
About one in ten waits for a 20–30 ms daemon tick. A smoothed center can
remain below 8 ms and miss this tail.

Local prediction now uses the maximum of the last 20 confirmed echoes.
The 8 ms threshold detects a recent daemon-tick delay. Display still requires
a confirmed echo in the current burst.

Local prediction is off by default. The measured local echo was about 4 ms
median and 22 ms p90 in the fast-median run. A silent `read -s` transition
cannot revoke confidence through output because it emits no bytes. Enable
**Predict local typing** under Settings → Appearance only after accepting this
risk. After a pause longer than 300 ms, the next key waits for its echo, local
and remote. The harness commands above measure the opt-in rendering paths.

The four-pane CPU guard used 200,000 bytes per second for 20 seconds.
CoreGraphics used 88.6% CPU in the earlier baseline and 67.3% now. The feeds
were 3.3 MB and 3.8 MB. That feed difference prevents a strict CPU comparison.
The current run used 13.47 CPU seconds over 20.01 wall seconds. Unit tests
confirm that 512-byte and larger feeds retain the frame-limited path.

Metal remains off by default. The harness used aggregated buffering and 200
samples. These results stop at SwiftTerm's display-update callback:

| Metal settings | Median | p90 |
| --- | ---: | ---: |
| transaction off, display sync on | 0.253 ms | 0.460 ms |
| transaction on, display sync on | 0.219 ms | 0.373 ms |
| transaction off, display sync off | 0.228 ms | 0.366 ms |

Run these variants with `--metal-presents-with-transaction` and
`--metal-display-sync off`. The callback precedes GPU presentation. Therefore
these small differences do not prove a scanout change. Rai keeps SwiftTerm's
defaults. It keeps display sync on because disabled sync can tear.

## Screenshot the running app

Bring rai to the front, read its window bounds, and capture just that window:

```sh
osascript -e 'tell application "Rai" to activate'
RECT=$(osascript -e 'tell application "System Events" to tell process "Rai" \
  to get {position, size} of front window' | tr -d ' ')   # → "x,y,w,h"
screencapture -x -o -R"$RECT" rai.png
```

- The `System Events` step needs **Accessibility** permission for the terminal
  running it. If it's denied, fall back to a full-screen grab:
  `screencapture -x -o rai.png`.
- `-x` silences the shutter; `-o` drops the window shadow.
- Retina displays capture at 2× — a 1512×949 window yields a 3024×1898 png.

## End-to-end checks against herdr — without disrupting live work

rai is a GUI client for the `herdr` daemon, which holds **real, running** agent
sessions. The cardinal rule:

> **Never split, close, or refocus another person's active agents.** Do all
> structural testing in isolated, throwaway workspaces created with `--no-focus`,
> and clean them up when done.

Inspecting state is always safe — the snapshot is read-only, and its array order
is the canonical (sidebar) order, so don't re-sort by `number`:

```sh
herdr api snapshot           # full ordered workspaces → tabs → panes + statuses
```

Throwaway-workspace pattern (this is how the reopen-tab and slot-ordering
behavior were verified live):

```sh
# create WITHOUT stealing focus, then find the new workspace id by diffing
before=$(herdr api snapshot | jq -r '.result.snapshot.workspaces[].workspace_id')
herdr workspace create --cwd /tmp --no-focus
after=$(herdr api snapshot | jq -r '.result.snapshot.workspaces[].workspace_id')
ws=$(comm -13 <(echo "$before" | sort) <(echo "$after" | sort))

# …exercise tab/pane/agent commands in "$ws", re-inspect via `herdr api snapshot`…

herdr workspace close "$ws"  # ALWAYS clean up
```

Rules that keep tests non-disruptive and correct:

- Pass `--no-focus` on every `create` / `agent start` so the user's view never
  jumps.
- Since herdr 0.7.5, `agent start` only wraps a **recognized** agent kind
  (`--kind claude|codex|…`) inside an **existing** pane sitting at a shell
  prompt — the old dummy-agent mode (`agent start test --tab … -- /bin/sh`)
  is gone. For structure tests, drive the pane's shell directly with
  `pane send-text` / `pane send-keys` instead; a plain shell never counts as
  a tracked agent anyway, so it proved nothing about agent status.
- A freshly created tab (and a new workspace's root) already has a
  **default shell pane** — that pane is your test surface.
- herdr refuses to close the **last** tab in a workspace
  (`{"code":"tab_close_failed"}`).
- Close every throwaway workspace when finished.

### herdr command quick reference

| command | purpose |
| --- | --- |
| `herdr api snapshot` | full runtime state (workspaces/tabs/panes/agents), canonical order |
| `herdr workspace create [--cwd P] [--focus\|--no-focus]` | new workspace (response includes the `root_pane`) |
| `herdr tab create --workspace <id> [--cwd P] [--label L] [--no-focus]` | new tab (seeds one default pane) |
| `herdr agent start <name> --kind <kind> --pane <id> [-- <agent args…>]` | start a recognized agent in an existing shell pane |
| `herdr pane send-text <paneID> <text>` | type text into a pane |
| `herdr pane send-keys <paneID> <key>` | send a key (`Enter`, `Escape`, `C-c`, …) |
| `herdr pane split <paneID> --direction <right\|down>` / `pane close <paneID>` | split / close a pane |
| `herdr workspace close <id>` / `herdr tab close <id>` | tear down |

The `poc/herdr_client.py` client (see the README) exercises the same socket in
Python if you'd rather not shell out.

### Isolated herdr lab (closed-tab e2e)

`scripts/herdr-lab.sh` runs a **named herdr session** (`railab`) with its own
state and sockets — the default herd and its persisted `session.json` are
never touched — plus a fake `claude` on the server's PATH that records its
argv and keeps a claude-named process alive, so agent detection works without
burning real agent sessions:

```sh
scripts/herdr-lab.sh start
HERDR_SOCKET_PATH=$(scripts/herdr-lab.sh socket) poc/closed_tab_e2e.py
scripts/herdr-lab.sh stop
```

`poc/closed_tab_e2e.py` replays the exact CLI sequences RaiModel issues for
closing and reopening tabs — structural contract (labels, rename, splits,
zoom, dead-workspace errors), the shell-readiness race, the single-pane agent
reopen (the herdr ≥0.7.5 `agent start --tab` regression), the multi-pane
shape rebuild, and the last-tab-of-space reopen (closing a workspace's only
tab closes the space; reopen recreates it under its label and adopts its
default tab). Exit code 0 means all checks passed.

rai launches an agent one of two ways, and the lab exercises both:
- **Fresh launch, no resume** (`launchAgent`, `launchAgentFromBridge`): herdr's
  own `agent start <name> --kind <kind> --pane <id>` — it waits for the pane's
  shell prompt and the agent's own readiness internally, so no delay is
  guessed and there's no window to lose text in (verified 5/5 at 0ms). rai
  declares no minimum herdr version, so a rejected `--kind`/`--pane` (pre-0.7.5
  herdr; the pane is left at a clean shell prompt either way) falls back to
  typing the bare launch command directly, same as the resume path below.
- **Resume, with a `first || fallback` shell chain** (reopen, shape rebuild):
  `agent start`'s trailing args exec straight into the agent binary, so they
  can't carry `||`. These type the resume command with `pane run`, then poll
  for the agent to appear and retype once if it didn't land — a fixed delay
  before a single blind attempt can guess wrong on a slow shell startup and
  silently drop the whole line.
