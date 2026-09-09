# Herdr 0.9 machine validation

## Candidate46 closeout

This section supersedes earlier pending machine-picker checks.

Candidate46 passed 877 Mac tests and 374 iOS tests with zero failures. The ordinary Mac suite skipped six environment-dependent tests.

Both new duplicate-machine boundary tests passed. Candidate45's live SSH suite already passed the surface-activation regression.

Mac Add, Cancel Setup, Online status, rename, disable, enable, and Remove passed through the interface.

The test used `UI43 Mac Disposable`, target `rai-lab-ui-mac`, and session `ui43-mac`.

Cancel Setup stopped the fixture before network access. The process exited and the interface reported cancellation.

The successful profile became `UI46 Mac Renamed`. Its disabled control rejected a navigation click. Enable restored Online status.

Remove deleted only the disposable profile. SSH confirmed that session `ui43-mac` remained running afterward.

Mac combined search showed both machines' `w1:p1` agents. The blocked filter retained only Lab Two.

Selecting that agent opened Lab Two's Claude `w1:p1` with an active terminal. The previous surface-activation error did not recur.

The connection-loss check blocked only fixture target `rai-lab-two` and terminated its app-owned tunnel.

Both clients retained the Claude agent row with “Disconnected — saved agent state.” Lab One remained Online.

The phone exposed a disabled agent button. Clicking it did not navigate. The Mac displayed the same disabled row.

The test restored the SSH configuration byte-for-byte. Neither Herdr server stopped.

The metadata agent then verified Online status on both clients and reopened Mac `w1:p1` with active controls.

One visual defect remains: the Mac Add form clips field labels and explanatory text at its fixed width.

The Candidate47 correction uses the existing grouped form style on Mac and gives the explanation its full wrapped height.

The sheet height increases to fit the controls. Phone layout remains unchanged. The correction awaits interface validation.

Evidence: `machines46-ui-checks.json`, `machines46-disconnect.json`, and `candidate46-checks.json` in `/private/tmp/rai09-391wxjtr`.

## Candidate44 interface checks

This section supersedes earlier pending checks for phone setup and notification taps.

Phone Add, Cancel Setup, Online status, and Remove passed on Candidate43.

The test used `UI43 Phone Disposable`, target `rai-lab-ui-ios`, and session `ui43-ios`.

The SSH fixture held setup before any network connection. Cancel Setup produced “Machine setup was canceled.”

The canceled fixture process exited. Releasing the hold allowed Add to save the profile and show Online.

Remove deleted only the disposable profile. Both original SSH profiles remained Online.

A separate SSH session listing confirmed `ui43-ios` remained running after profile removal.

Simulator settings had disabled notifications for the exact isolated app. The test enabled notifications and persistent banners.

Candidate43 then exposed a notification navigation defect. A current notification could report “The workspace view is closed.”

Candidate44 corrected repeated phone close requests. Its full iOS suite passed 373 tests with zero failures.

Current notification taps passed with Rai active and with Rai in the background.

Both taps opened Lab One. The pane picker showed Codex `w1:p1` selected and Lab One recorder panes.

A stale-boot notification closed the current view and showed the expected changed-server error.

It opened no endpoint and offered no input or permission actions. The test dismissed the error afterward.

Simulator injection verifies local notification delivery and navigation. It does not verify APNs network delivery.

Mac search showed both machines' `w1:p1` agents. The blocked filter retained only Lab Two.

Mac agent selection exposed `surface_inactive` before pane focus. Source inspection found focus occurred before surface activation.

The correction validates boot identity, activates the captured endpoint, checks generation, then focuses the pane.

The live machine regression test now verifies agent selection, input readiness, target identity, and unchanged other-machine state.

Candidate43 also omitted Add from the Mac picker footer. The parent corrected its toolbar grouping.

Candidate45 passed the full Mac suite and the extended live SSH test, including the activation regression.

Both Mac corrections still require interface validation.

Remaining machine interface checks:

- Mac Add, Cancel Setup, Remove, rename, disable, and enable.
- Mac filtered agent navigation after the activation correction.
- Retained disconnected agent rows and disabled navigation on both platforms.

Evidence: `/private/tmp/rai09-391wxjtr/machines44-ui-checks.json`.

`git diff --check` passed. The quality scan reported 68 repository findings; it did not provide a clean gate.

Evidence: `/private/tmp/rai09-391wxjtr/machines45-quality.json`.

### Duplicate-pane coverage audit

The live SSH tests cover duplicate resource identity, rename isolation, reconnect invalidation, launch isolation, and agent focus isolation.

Notification tests use duplicate pane IDs across machines. Candidate44 interface checks verified current and stale notification routing.

Existing tests separately cover input identity, stale closure confirmation, history identity, graphics reset, and scoped notification decisions.

Source inspection found full machine, connection, and view checks before endpoint operations.

The phone rejects foreign state before graphics resolution. Disconnect clears graphics and queued operations.

Two supplementary boundary tests now cover foreign machine operations and machine switches with duplicate pane and image keys.

Both supplementary tests passed in Candidate46. The first supplementary iOS build found two test-only optional-chaining errors, now corrected.

The supplementary Mac run failed during dependency checkout. It did not execute tests.

The failed frozen copy remains at `/private/tmp/rai09-391wxjtr/machines45-regression`.

Its product source matched Candidate45. Evidence: `machines45-regression-source-equality.json` in the lab root.

Two-server interface tests still lack paired isolation checks for input, pane closure, history, graphics, and permission responses.

Boundary tests do not replace those live checks.

## Candidate43 closeout

This section supersedes earlier pending-check notes below.

Candidate43 passed 876 Mac tests, 371 iOS tests, and three configured native/SSH tests, with zero failures.

The ordinary Mac run skipped six environment-dependent tests. The separate live run exercised native handshake and both SSH tests.

Evidence: `/private/tmp/rai09-391wxjtr/candidate43-checks.json` and `/tmp/rai09-candidate43-live-tests.log`.

Both native agent launches passed through the interface:

- Mac: `mac43-launch` on Lab One `w2:p6`.
- Phone: `phone43-launch` on Lab One `w2:p7`.
- Recorder line count changed from five to six to seven.
- Lab Two retained its original Claude fixture.

Evidence: `launch43-evidence.json`, `launch43-mac-recorder.txt`, and `candidate43-checks.json` in the lab root.

Phone machine management passed rename, disable, enable, and restoring the original label.

The parent observed the disabled row and disabled navigation. Other profiles remained Online.

An independent catalog read confirmed both original labels and enabled profiles afterward.

Evidence: `machines43-phone-management.json` in the lab root.

Phone combined search showed both machines' `w1:p1` agents with their separate labels and states.

The blocked filter retained only Lab Two. Selecting that row opened the Claude pane on Lab Two.

Lab One retained focus on `w2:p7` throughout this phone navigation.

Evidence: `machines43-phone-search.json` and `machines43-labone-after-phone-search.json` in the lab root.

Candidate43's seven `MachineBridgeTests` passed, including stale notification rejection and connection-scoped workspace confirmation.

The notification tests wait for fresh directory state. They reject changed boots and prevent fallback until explicit selection.

Real SSH tests prove duplicate pane IDs stay separate and reconnect invalidates old connections.

Nine notification identity and payload tests passed again during closeout without simulator or server focus changes.

Logs: `/tmp/rai09-candidate43-ios-tests.log` and `/tmp/rai09-machine-notification-closeout-tests.log`.

### Remaining interface checks

- Phone notification taps: authorize banners, tap the current Lab One notice, then verify stale-boot rejection.
- Mac picker: search duplicate agents, filter states, rename, disable, enable, and restore the chosen profile.
- Both pickers: complete Add/Remove and Cancel Setup checks through the interface. Existing CLI checks already passed.
- Both pickers: verify retained disconnected agent rows and disabled navigation during a connection failure, then reconnect.

Complete notification tests before removing profiles. Re-adding a profile creates a new identity and invalidates the prepared payload.

Graphics disabled-policy interface checks already passed on both platforms. Herdr's restart-only policy remains the documented upstream limit.

### Simulator notification commands

The parent owns simulator control. These commands target only the isolated simulator and lab application.

The installed app appears as **Rai Remote** in Settings.

Enable Settings → Notifications → Rai Remote → Allow Notifications, Banners, and Notification Center.

Candidate43 requests notification permission at startup and refreshes permission state when it becomes active.

It has no in-app shortcut to notification settings. Simulator injection does not require production APNs credentials.

From another selected machine, send the current notification and tap it:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun simctl push 2F9F0DF0-F78E-4DF2-A7E7-8AE1AE30CE8D com.whetstone.rai.ios.lab.e2e-56b425104c06 /private/tmp/rai09-391wxjtr/machines-simulator-push-current.json
```

Expected result: refresh machines and open Lab One, session `default`, workspace `w1`, tab `w1:t1`, pane `w1:p1`.

Lab Two must remain unchanged. No approval, denial, or reply controls should appear.

Then send the stale notification and tap it:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun simctl push 2F9F0DF0-F78E-4DF2-A7E7-8AE1AE30CE8D com.whetstone.rai.ios.lab.e2e-56b425104c06 /private/tmp/rai09-391wxjtr/machines-simulator-push-stale.json
```

Expected error: “This agent or server changed. Open Machines to review its current state.”

No endpoint may open until the user explicitly selects a machine. No input or permission decision may occur.

Simulator injection proves local delivery and navigation only. It does not prove APNs network delivery.

### Disposable Git dependency

Remote plugin review initially failed because the owned SSH container lacked Git.

The parent authorized Git installation inside `rai09-ssh-e2e-56b425104c06`. Its ownership label matched `e2e-56b425104c06`.

Git 2.47.3 now runs through SSH. This installation did not approve, build, or start plugins.


## Scope

This work adds machine management, combined agents, machine notifications, and safe resource routing on macOS and iOS.

Machine identity includes the saved profile and session. Agent identity also includes connection, server boot, and pane.

Labels never define identity. The shared picker shows target and session details to distinguish duplicate names.

Metadata connections do not activate surfaces or resize terminals. Foreground views activate their own surfaces before mutations.

## Implementation

- Add, rename, remove, enable, and disable use the documented Herdr CLI.
- Reconnect refreshes connection identity. Old connections cannot resolve resources.
- Combined agents support text search and status filters.
- Disconnected entries retain agent rows and disable navigation.
- Setup uses a PTY and requires a fresh, explicit answer for each prompt.
- Output truncation disables approval. Cancellation stops setup and escalates termination.
- CLI capture bounds both output streams and enforces deadlines and cancellation.
- SSH discovery uses strict host checks and a 20-second command deadline.
- Phone reconnect requests fresh directory state before opening a machine.
- Machine notifications include profile, session, server boot, and pane identity.
- Notification navigation resolves the target against fresh directory state.
- Invalid, removed, or changed targets cannot fall back to a different pane.
- Machine notification payloads omit legacy pane IDs, permission IDs, and actionable categories.
- Initial snapshots and reconnects do not replay old notices.
- Disconnect, removal, and server changes retract old notification identities.
- Graphics policy refreshes every two seconds. Disabled graphics leave text and input available.
- Rai retains unfiltered image data and reapplies the observed graphics policy.
- Legacy notifications capture the local host connection before delivery.
- The server rejects actions after host changes or remote host selection.
- Cold notification navigation validates its captured host after application startup.
- Older phone registrations receive banners without action or pane-routing fields.
- Agent launch captures machine, connection, view, server boot, pane, name, and kind.
- Launch uses `agent.start` on a pinned public API socket without retries.
- A failed focus request cannot change a successful launch into a reported failure.
- Setup cancellation kills the owned process group, including children that ignore termination.

## Disposable SSH fixture

The fixture runs two accounts inside one owned Docker container.

- Root: `/private/tmp/rai09-391wxjtr`
- Container: `rai09-ssh-e2e-56b425104c06`
- Ownership label: `rai.lab.owner=e2e-56b425104c06`
- Published address: `127.0.0.1:56422`
- SSH aliases: `rai-lab-one` and `rai-lab-two`
- Session: `default` on both accounts
- Duplicate pane IDs: `w1:p1` and `w2:p1`
- SSH config: `/private/tmp/rai09-391wxjtr/ssh-fixture/config`

The fixture uses a generated identity and dedicated known-hosts file. Tests never read the private key.

The fixture permits local stream forwarding. Conflicting sshd forwarding restrictions initially caused failures and were corrected.

Herdr closes inactive endpoint views that attempt mutations. The transport test now activates its foreground surface first.

## Passed checks

The isolated SwiftPM snapshot passed 27 focused tests, with zero failures and zero skips.

The tests cover catalog validation, setup prompts, command deadlines, resource identity, graphics policy, and notification routing.

Real SSH tests verified these conditions:

- Both machines connect through separate tunnels.
- Duplicate pane IDs remain separate resources.
- Renaming one workspace leaves the other machine unchanged.
- A different server boot cannot authorize a mutation.
- Reconnect invalidates the old connection identity.
- Reconnecting one machine preserves the second connection.
- Both machines expose their agent records.

Earlier CLI checks verified rename, disable, enable, remove, and add against the disposable catalog.

Removing a profile preserved both remote servers. Re-adding created a new profile ID.

Evidence files:

- `/tmp/rai09-machines-final-tests.log`
- `/private/tmp/rai09-391wxjtr/machines-cli-checks.json`
- `/private/tmp/rai09-391wxjtr/machines-transport-state.json`
- `/private/tmp/rai09-391wxjtr/machines-validation-hashes.json`

Test executable SHA-256:

```text
29ac43f57bac3f290109ea637d48049ca30f6ae9145f1890ba3f79873f263e7a
```

The source hash file identifies the independent snapshot. Candidate39 runs the combined platform gates separately.

The command runner later gained an optional process environment. Its three regression tests passed again.

Additional log: `/tmp/rai09-machines-command-env-tests.log`.

`git diff --check` passed.

The quality scan reported repository-wide findings, including Swift test discovery false positives and machine state-machine complexity.

No quality baseline or instruction file was changed.

## Remaining combined validation

The parent agent owns the combined simulator tests and native UI validation.

Phone tests cover machine selection, reconnect, disconnected rows, notification freshness, and changed server boots.

Simulated push payload:

```text
/private/tmp/rai09-391wxjtr/machines-simulator-push.json
```

This payload targets Lab One, pane `w1:p1`. It does not contact APNs.

Live graphics helper:

```sh
python3 /private/tmp/rai09-391wxjtr/graphics39-reload.py on
python3 /private/tmp/rai09-391wxjtr/graphics39-reload.py off
python3 /private/tmp/rai09-391wxjtr/graphics39-reload.py restore
```

The helper only changes the owned `graphics36-stable` fixture. It verifies the process and calls `server.reload_config` before checking policy.

Herdr 0.9 does not apply graphics policy changes during reload. The server requires a restart.

The `on` check therefore failed with `feature_disabled`. The reload response reported `partial` with this diagnostic:

```text
terminal.kitty_graphics changes require restarting Herdr; kept current setting
```

Upstream `src/app/mod.rs:847` retains the running policy. Its `reload_config_keeps_kitty_graphics_until_restart` test verifies this requirement.

Inspected upstream commit: `4b5e9bda239a0b6903889062d756424578e94691`.

Live evidence: `/private/tmp/rai09-391wxjtr/graphics42-reload-limit.json`.

Same-server graphics toggles cannot pass against Herdr 0.9. Validate enabled and disabled server instances separately.

The fixture configuration was restored to its original disabled setting. Its server remained running.

## Limits

Herdr agent metadata does not provide a verified permission nonce for machine notices.

These notices open the exact agent for review. They never send Allow, Deny, or Reply actions.

Tests did not send production notifications, install production plugins, upload builds, or change real SSH profiles.

## Agent launch and notification follow-up

The first launch run passed 16 focused tests, including real SSH launch and duplicate-machine isolation.

The recorder launched Codex only inside Lab One. It never contacted an agent provider.

A repeat run exposed retained Herdr agent state. The test now creates and removes a dedicated launch pane.

The test compares recorder output before and after launch. Existing recorder output cannot satisfy the new assertion.

The command runner preserves inherited configuration when callers provide no environment override.

An earlier override regression hid the fixture catalog. A regression test now covers inherited and explicit environments.

The phone tests cover scoped notification input and agent launch identities.

Use the complete disposable environment for SSH tests:

```python
import json
import subprocess
from pathlib import Path

root = Path("/private/tmp/rai09-391wxjtr")
env = json.loads((root / "lab.json").read_text())["environment"].copy()
env["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
env["RAI_MACHINE_E2E_ROOT"] = str(root)
subprocess.run([
    "/usr/bin/swift", "test", "--jobs", "4",
    "--package-path", "/private/tmp/rai09-machines-snapshot",
    "--scratch-path", "/private/tmp/rai09-machines-snapshot/build-local",
    "--filter", "MachineTransportTests"
], env=env, check=True)
```

`RAI_MACHINE_E2E_ROOT` alone cannot isolate the catalog. The lab manifest supplies configuration, socket, and data paths.

The final quality scan reported 157 repository findings against Git HEAD.

Machine complexity findings remain `MachineCommandRunner.execute` at 17 and `MachineDirectory.perform` at 18.

The report also counts Swift test discovery and type-length findings. No quality baseline was changed.

Final quality report: `/tmp/rai09-machines-final-quality.xml`.

## Final focused results

All 19 final focused tests passed, with zero failures and zero skips.

The final suite includes inherited environment, scoped notification actions, focus failure, child cancellation, and real SSH launch.

Both SSH transport tests passed again without fixture repair. Launch creates and closes its own temporary pane.

Evidence:

- `/tmp/rai09-machines-review-final-tests.log`
- `/tmp/rai09-machines-repeat-tests.log`
- `/private/tmp/rai09-391wxjtr/machines-agent-launch-result.json`
- `/private/tmp/rai09-391wxjtr/machines-final-validation-hashes.json`

Final test executable SHA-256:

```text
4a27d1dff5fa5b811a462834aff434f7792039f59e21169f34551189584333be
```

`git diff --check` passed after these changes.

The parent must run the combined iOS gate and native interface checks on the frozen candidate.

## Cancellation and closure review follow-up

Process runners now capture process-group ownership when the process starts.

Cancellation kills the owned group even when the parent exits before escalation or before cancellation begins.

Seven cancellation tests passed. They cover inherited pipes, inherited terminals, output limits, and children that ignore termination.

Log: `/tmp/rai09-machines-cancellation-final-tests.log`.

Legacy phone workspace confirmation now captures the host connection when the user opens the confirmation.

Missing, changed, or disconnected connections prevent submission. Group closure also checks its captured connection before submission.

The protocol preserves the captured identity. Older messages decode with no identity and require server rejection.

New phone regression coverage verifies stale and missing identities, matching submission, and disconnected rejection.

The final combined source snapshot compiled after the closure protocol change.

Thirteen protocol and cancellation tests passed. Seven bridge audit tests also passed.

Logs:

- `/tmp/rai09-machines-closure-final-tests.log`
- `/tmp/rai09-machines-closure-audit-tests.log`

`git diff --check` passed. The final repository quality scan reported 154 findings against Git HEAD.

Quality report: `/tmp/rai09-machines-closure-quality.xml`.

Fresh UI launch shells were prepared without changing focus: Lab One `w2:p6` for macOS and `w2:p7` for iOS.

The recorder held four lines before these interface tests. Each launch must append one new recorder line.

Fixture preparation evidence: `/private/tmp/rai09-391wxjtr/machines-ui-launch-panes.json`.


## Candidate47 history width correction

Candidate46 exposed a history failure when a Mac viewport exceeded the shared terminal width.

The owned `commands22` pane `w1:p5` accepted final-row columns 0 through 50. Column 51 failed.

History now checks the final row and finds its last valid column with bounded single-cell reads.

The correction preserves request identity, pane identity, row range, content revision, and truncation state.

Invalid rows remain errors. A changed revision restarts the existing bounded history capture.

The correction never sends input, changes focus, or resizes a terminal.

New regressions cover 400 Unicode rows, width mismatch, revision changes during probes, and invalid final rows.

Swift parsing, Python syntax validation, and `git diff --check` passed. Candidate47 execution and interface checks remain pending.

Evidence:

- `/private/tmp/rai09-391wxjtr/history47-pane-get.json`
- `/private/tmp/rai09-391wxjtr/history47-column-probe.json`
- `/private/tmp/rai09-391wxjtr/history47-width-boundary.json`


## Candidate48 native history bounds

A narrower projected viewport also omitted final-row text without returning an error.

At revision 598, column 20 returned 15,096 characters. Columns 33 and 50 returned 15,109 characters.

The native `pane.copy_motion` operation returned final column 33 with `line_end` and the same revision.

History now uses this native operation before selection. This replaces the Candidate47 width probes.

Rai validates the response type, pane, final row, content revision, and column bounds before selection.

The selection preserves request identity, complete row bounds, and truncation state. Existing stale-content retries remain bounded.

Regressions cover wider and narrower views, stale motion, omitted earlier rows, invalid targets, and invalid columns.

Swift parsing, Python syntax validation, and `git diff --check` passed. Candidate48 test execution remains pending.

The core quality scan reports 19 branch findings against Git HEAD. No quality baseline changed.

Evidence:

- `/private/tmp/rai09-391wxjtr/history47-narrow-selection-audit.json`
- `/private/tmp/rai09-391wxjtr/history47-line-end-audit.json`
- `/private/tmp/rai09-391wxjtr/history48-quality.json`


## Candidate48 app validation

The Mac Add form displays all fields, the complete explanation, and both buttons without clipping.

Cancel returned to the unchanged machine list. No machine was added.

Mac and primary-phone history captures each contain all 400 retained markers and the complete final prompt.

Both captures contain 15,109 characters and have identical SHA-256 fingerprints.

The shared terminal has 89 columns at revision 616. The final row is 406; its text ends at column 33.

Screenshots show a wider Mac viewport and a narrower phone viewport. Raw projected column counts were not collected.

Three Mac history reloads returned the same text. The fixture produced no new output during these reloads.

Mac RSS measured 136,480 KiB before the series, 144,240 KiB after one reload, and 133,680 KiB after three.

The baseline follows one earlier history capture. These samples do not establish long-term memory behavior.

The original fixture content remains unchanged. The phone returned to its original portrait orientation.

Candidate48 suites passed: Mac 879 tests with six skips; iOS 376 tests. The parent supplied these results.

Evidence:

- `/private/tmp/rai09-391wxjtr/machines48-ui-checks.json`
- `/private/tmp/rai09-391wxjtr/history48-mac-capture.txt`
- `/private/tmp/rai09-391wxjtr/history48-phone-capture.txt`
- `/private/tmp/rai09-391wxjtr/history48-mac-viewport.png`
- `/private/tmp/rai09-391wxjtr/history48-phone-viewport.png`
- `/private/tmp/rai09-391wxjtr/history48-width-boundary.json`

The parent owns the Mac Share destination check. Prompt validation now owns Computer Use.


## Candidate49 remote connection review

Review findings 1 and 4 were confirmed against the legacy remote-session path.

Independent Mac and phone views now capture explicit remote host, session, and socket details.

Each view creates and owns its SSH tunnel. Main-window session changes do not terminate these tunnels.

Plugin installation and removal use the captured remote host. They do not fall back to the Mac installer.

The phone retains only its exact server-created remote view during main-session changes.

A bridge transport change still clears that view. Native server boot checks still reject stale requests.

New regressions cover unowned identities, transport loss, independent tunnel paths, remote command routing, reconnect, and cleanup.

Swift parsing and `git diff --check` passed. Frozen Candidate49 test execution remains pending.

The live SSH regression requires the complete owned lab environment and `RAI_MACHINE_E2E_ROOT`.

Evidence: `/private/tmp/rai09-391wxjtr/remote49-handoff.json` and `/private/tmp/rai09-391wxjtr/remote49-combined-diff.patch`.


## Candidate49 live SSH results

All three MachineTransportTests passed with zero skips and zero failures on frozen Candidate49.

The new legacy-remote regression verified separate Mac and phone tunnel paths for one captured remote context.

Stopping the main tunnel preserved both independent views. Reconnect replaced only the Mac view's tunnel.

Both plugin-removal checks ran on the owned remote host and rejected unique missing plugin identifiers.

The Mac plugin installer received no calls. Final view closure removed both independent API sockets.

Existing duplicate-resource isolation and remote agent-launch tests also passed. Their owned temporary pane closed during teardown.

Both saved profiles remain enabled with their original identifiers and targets.

Lab One's default, ui43-mac, and ui43-ios servers remain running. Lab Two's default server remains running.

The tests did not stop these remote servers or change profile settings.

Evidence:

- `/private/tmp/rai09-391wxjtr/remote49-machine-transport-tests.log`
- `/private/tmp/rai09-391wxjtr/remote49-live-invocation.json`
- `/private/tmp/rai09-391wxjtr/remote49-after-transport-tests.json`

The shared Mac build cache was released to the updater archive check.
