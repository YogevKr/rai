# Plugins, links, notifications, and agent views

## Current validation status

Both platforms passed local and SSH plugin review cancellation, integration installation controls, notifications, links, and basic agent filtering.
Both platforms also passed plugin enable, disable, unlink, and managed removal, including removal cancellation.
Both platforms installed and uninstalled a reviewed GitHub plugin. File hashes and its commit matched the review.
Phone configured a labeled Codex filter with descending pane order. Clearing restored the workspace list.
Named-local review preserved the primary Mac session and the existing plugin inventory.
The latest records appear in the completion sections below. Earlier logs remain historical evidence.

Remaining material checks:

- Audible notification sound.
- Direct Mac Command-click, which the current CUA click interface does not support.

Both apps passed native-socket notification reconnect and no-replay checks. The completion record below states the transport scope.

Metadata editor checks appear in `herdr-09-metadata-validation.md`.

## Implementation

The Plugins and Views sheet supports installed plugins, integrations, visible links, and filtered agent views.

Plugin controls list, enable, disable, and unlink installed plugins through the selected view's API socket.

Selected local sessions support reviewed GitHub installation and managed uninstall through the Rai installer.

Remote installation uses the selected machine and session through a foreground SSH terminal.

The same remote process prints the preview and receives its approval. It never uses `--yes` or a local fallback.

The wrapper checks the active machine identity and rejects stale approval IDs, unexpected prompts, and truncated previews.

Closing the review cancels pending approval. Disconnect cancels the owned SSH process.

Remote managed uninstall uses the same selected SSH target after the removal dialog.

Each install preview now has a UUID. Confirmation and cancellation check that UUID before changing the pending install.

This prevents one window from confirming another window's replacement preview.

Plugin links use captured pane coordinates, boot identity, content revision, scroll offset, and URL.

The host validates captured content before calling `pane.link.activate`. The client never sends a URL to the plugin handler.

The native link handler offers a web link only after Herdr returns `handled: false`.

The native endpoint accepts `integration.list` and `integration.install`. Plugin and agent-view methods use the API transport.

Filtered views use the existing AgentView contract. The sheet supports status, agent, workspace, token, and sort controls.

Snapshots preserve agent-view labels, ordered pane identities, and tab status segments.

`visibleAgents` follows the server order when a filtered view is active. An empty filtered order shows no agents.

Semantic notification events preserve their category, text, sound, position, agent, and target identities.

Each connected view stores at most 50 notifications. Disconnect removes the stored events and prevents replay.

Local controls enable banners and sounds. Endpoint errors always appear, regardless of banner settings.

## Verification

The focused validation package copies sources into an independent directory:

`/var/folders/dj/7c4nlr0s6256kkqpqpk0r3pm0000gn/T/rai-plugin-validation-p2c67kgp`

Command:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --jobs 4
```

Result: 22 tests passed, including six plugin tests, twelve metadata tests, and four foreground terminal tests.

The package also compiled the native plugin, metadata, and notification views on macOS.

Log: `/tmp/rai-plugin-validation-tests.log`

Tests cover semantic wire decoding, invalid enums, mandatory errors, snapshot fields, filtered order, typed requests, inventory validation, and stale links.

The native view-model and bridge files passed Swift syntax parsing.

The shared plugin, metadata, and notification views compiled against the iOS simulator SDK.

Log: `/tmp/rai-plugin-validation-ios.log`

Foreground terminal tests verify explicit approval before writes, stale machine rejection, unexpected prompts, and truncated preview rejection.

Those tests exposed a buffered-read defect in MachineSetupProcess. POSIX reads fixed the prompt stall.

A separate app test checks that plugin audit records omit source, reference, and response content.

The branch quality gate remains open. New plugin type-size and test-fixture duplication findings remain.

Log: `/tmp/rai-plugin-quality.log`

Later Candidate43 records provide the integrated build and isolated UI results.

## Historical evidence checkpoints

The following evidence audit identifies completed checks and remaining UI cases. Earlier test results remain historical evidence.

The parent agent owns the shared CUA apps. This agent did not operate them.

Later completion sections record the E2E checks that passed.

## Review corrections

Native URL detection now captures plain printed URLs, with the same revision and offset checks as OSC links.
Only a matching server URL can open the browser. Reconnect clears pending link requests.

Plugin requests use a separate socket and a ten-second deadline. Cancellation closes that socket without replay.
Local preview cancellation stops its Git process and removes its temporary checkout.
Cancelled previews cannot create later approvals. Endpoint failure prevents local installation.

Window-title events update only their owning endpoint view. Reset and disconnect remove the title.
Both native views show the title through their navigation presentation.

The focused source copy ran 45 tests: 44 passed, and one isolated Herdr handshake test skipped.
The skipped test requires RAI_ENDPOINT_TEST_ROOT. Parent validation owns that live fixture.
All new plugin lifecycle and title tests passed.

Source copy: `/var/folders/dj/7c4nlr0s6256kkqpqpk0r3pm0000gn/T/rai-plugin-closeout-woo72388`.
Log: `/tmp/rai-plugin-closeout-tests.log`.

The parent can run plugin, agent-view, notification, link, and title UI checks with the prepared Plugin39 fixture.
Instructions: `/tmp/rai09-391wxjtr/plugin39-ui-checks.md`.
The fixture preserves existing command and popup configuration.

The branch quality gate still reports 130 changed existing major findings.
Log: `/tmp/rai-review-quality.log`.


## Named local sessions

Local plugin review now captures the selected endpoint socket and boot.
Independent named sessions work when the main app selects another session.
Confirmation checks the preview UUID, socket, and boot before installation.
Install and uninstall commands use the captured socket and local host configuration.
Cancellation retains preview ownership and removes temporary checkouts.

Seven lifecycle tests passed in the isolated source copy.
They cover stale boot rejection, wrong endpoint rejection, command routing, cancellation, and checkout cleanup.
Log: `/tmp/rai-plugin-named-session-tests.log`.

The RaiApp quality check reports 64 branch findings. It does not pass.
Log: `/tmp/rai-plugin-named-session-quality.log`.
Candidate43 later passed the combined builds and named-local UI checks for this correction.


## Phone request rejection

Rejected plugin requests now return an error with the request ID.
Busy requests and stale preview confirmations no longer leave the phone waiting.
The host retains the rejection until another plugin request succeeds.
An earlier request's late result cannot replace that rejection during combined state delivery.
The regression covers both rejection paths and a late earlier result.
Log: `/tmp/rai-plugin-close-activation-tests.log`.


## Candidate43 evidence audit

Candidate39 recorded Mac plugin disable and enable against the server inventory.
It recorded Mac Links actions and phone native taps for two plugin URLs.
Each activation retained plugin, action, handler, and pane identities.
The phone opened the plain URL in Safari without adding a plugin action.
Both platforms displayed one matching notification and the expected filtered agent lists.
The Working filter showed an empty list. Clearing the filter restored the workspace list.
Candidate43 recorded window-title set and clear on both platforms. Phone title changes preserved the Mac title.

Sources: `candidate39-checks.json` and `candidate43-checks.json` under `/private/tmp/rai09-391wxjtr`.
The integrated validation document records the metadata, notification, and agent-view observations.
Sound remained unverified at this checkpoint. Later completion records cover notification replay.
Direct Mac Command-click remains unverified because CUA lacks held-modifier clicks.

### Historical phone plugin checklist — completed

1. Open the selected endpoint's Plugins and Views sheet. Refresh Plugins and verify the fixture ID and version.
2. Disable `rai.lab.phone.lifecycle43`. Refresh and verify `enabled: false` in that endpoint's inventory.
3. Enable it again. Verify `enabled: true`. Preserve the separate `rai.lab.validation` link fixture.
4. Complete install review and cancellation for local and SSH targets, as described below.
5. After link checks finish, review unlink and cancel it. Verify the registry remains unchanged.
6. Unlink the disposable registration and verify its removal.
7. Use `rai.lab.phone.managed43` for managed uninstall. Cancel first, then uninstall and verify removal of its owned directory.

Phone lifecycle checks passed later on Candidate43, as recorded below.
Mac later passed unlink and managed uninstall, as recorded below.

### Historical integration checklist — completed

1. Open Integrations and select Refresh Integrations on the selected endpoint.
2. Verify each row's target, state, and available actions against that endpoint's `integration.list` response.
3. Select an integration whose writable paths belong to the isolated fixture.
4. Select Install or Update. Verify the completion result and the same endpoint's new integration state.
5. Verify only the fixture-owned integration files changed. Repeat refresh to confirm the reported state persists.

Use isolated Claude or Codex paths when their upstream installer respects the fixture overrides.
Other integration targets need separate path isolation before installation checks.
Candidate43 later established native integration listing and installation, as recorded below.

### Historical named-local review checklist — completed

1. In the primary Mac window, open the sidebar session menu. Select Local Sessions, then running `graphics36-stable`.
2. In the independent Mac window or phone Workspace View, open Machines. Select `This Mac · commands22`.
3. Open Plugins. Review `ogulcancelik/herdr-plugin-examples/agent-telegram-notify` without approving installation.
4. Verify the preview includes its source, resolved commit, and complete manifest.
5. Cancel the review. Verify the waiting state clears and the view remains usable.
6. Verify the plugin registry remains unchanged and the review's temporary checkout disappears.
7. Repeat on the other platform while the primary Mac model still selects the different session.

These steps validate the named-session correction. Existing unit tests cover captured socket, boot, UUID, and cancellation ownership.
Candidate43 later passed this flow on both platforms, as recorded below.

### SSH review checkpoint

Candidate43 Mac and phone review attempts reached Lab One but failed before the approval prompt.
Both reported a remote command exit with a missing-file error.
Fixture inspection confirmed Git was absent: `command -v git` found nothing, and `git --version` returned 127.
The parent authorized Git installation inside the owned SSH fixture container.
The machines agent installed Git and verified version 2.47.3 through SSH.
The existing server remained running. No plugin approval, build, startup, or focus change occurred.
The parent then recorded successful preview display and cancellation on both Candidate43 apps.
The preview showed commit `18709cdc851dd63ed0543eb8388343a5446fd8d8`, three actions, no build or startup commands, and one event hook.
Mac Cancel showed `plugin install cancelled`. Phone Cancel removed the install buttons.
The preview did not receive approval.

Independent SSH inspection afterward found an empty Lab One plugin inventory and no remaining installer or Git process.
Both original Herdr server processes remained alive.
No pre-review inventory was recorded. This audit cannot establish a before-and-after inventory comparison.
UI record: `/tmp/rai-remote-review43-ui-evidence.json`.
Independent post-cancel record: `/tmp/rai-remote-review43-audit.json`.
This checkpoint does not authorize plugin approval, build commands, or startup commands.

### Source identity

Candidate43 matches all 196 current implementation files under `Sources` and `ios/rai-ios`.
The audit found no changed, missing, or new implementation files.
Manifest: `/private/tmp/rai09-391wxjtr/candidate43-source-manifest.json`.
Audit: `/tmp/rai-candidate43-source-audit.json`.


### Disposable phone fixtures

`Phone Lifecycle 43` uses ID `rai.lab.phone.lifecycle43` and version `0.1.0`.
Its local manifest is `/private/tmp/rai09-391wxjtr/phone-plugin43/herdr-plugin.toml`.
It has no actions, build commands, startup commands, or event hooks.
Use it for phone enable, disable, removal cancellation, and unlink checks.
Setup evidence: `/tmp/rai-phone-plugin43-fixture.json`.

`Phone Managed 43` uses ID `rai.lab.phone.managed43` and version `0.1.0`.
Its managed directory is `/private/tmp/rai09-391wxjtr/config/herdr/plugins/github/rai.lab.phone.managed43-b08d4c75655e`.
It has no executable commands or hooks.
The fixture uses synthetic managed-source metadata through Herdr's `plugin.link` contract. It contains no downloaded source.
Use it only to validate cancellation and managed-file removal. It does not establish GitHub installation coverage.
Setup evidence: `/tmp/rai-phone-managed43-fixture.json`.

Both registrations target only the `commands22` socket and private Herdr configuration.
Creating them did not change focus. The existing `rai.lab.validation` registration remained enabled.
The phone UI checks for both fixtures passed, as recorded below.


### Phone lifecycle completion

Candidate43 phone Disable showed Disabled. Enable restored Enabled.
Canceling removal preserved `Phone Lifecycle 43`. Unlink then removed its row.
Canceling managed removal preserved `Phone Managed 43`. Uninstall Managed Files then removed it.
These observations came from the parent's CUA session.

Independent inventory inspection found only enabled `rai.lab.validation` afterward.
The local fixture manifest remained on disk after unlink.
The managed fixture directory was absent after uninstall.
The registry evidence and file checks agree with the phone results.
Evidence: `/tmp/rai-phone-plugin43-after.json`.

### Safe integration fixture

The integration fixture uses SSH Lab One, session `default`, inside the owned SSH container.
The server's actual home is `/home/labone`. No Mac home override is required.
The fixture created `/home/labone/.claude` and `/home/labone/.codex` only after confirming both paths were absent.
Each directory contains `.rai-integration43-owned` with value `metadata_rules-integration43`.
The server environment has no Claude or Codex path override.
Upstream therefore resolves integration files under those two fixture-owned directories.
Both targets report `available: true` and `state: not_installed`.
Baseline: `/tmp/rai-integration43-before.json`.

Mac controls: select SSH Lab One, open Plugins, choose Integrations, then select Refresh Integrations.
Select the `claude` row's Install or Update button. Refresh again and verify `current`.
Phone controls: select SSH Lab One in Workspace View, open Plugins and Views, then choose Integrations.
Select Refresh Integrations, then the `codex` row's Install or Update button. Refresh and verify `current`.
After each operation, verify the selected target's files and preserve the other target's baseline.
The following completion record covers these installation checks. Fixture preparation itself did not install an integration or change focus.


### Integration installation completion

Candidate43 Mac installed Claude on SSH Lab One. Refresh showed `current`.
Candidate43 phone installed Codex on the same endpoint. Refresh showed `current` for both Codex and Claude.
These observations came from the parent's CUA session.

Independent inspection confirmed both targets remain available and current.
Claude created exactly `hooks/herdr-agent-state.sh` and `settings.json` under `/home/labone/.claude`.
Codex created exactly `herdr-agent-state.sh`, `hooks.json`, and `config.toml` under `/home/labone/.codex`.
Both directories retained their owned markers. No additional files appeared inside either directory.
Both hook scripts have mode `0755`. Their SHA-256 hashes match the upstream integration assets.
The baseline contained only the two markers. All five installed files belong to the isolated container home.

Baseline: `/tmp/rai-integration43-before.json`.
File hashes, modes, state, and UI observations: `/tmp/rai-integration43-after.json`.
These checks establish the installation controls. They do not claim that a real coding agent executed the installed hooks.


### Named-local review completion

The parent selected `graphics36-stable` in the primary Mac window.
The independent Mac window and phone selected `This Mac · commands22` through Machines.
Both reviewed `ogulcancelik/herdr-plugin-examples/agent-telegram-notify` and displayed source, resolved commit, and TOML.
The resolved commit was `18709cdc851dd63ed0543eb8388343a5446fd8d8`.
Both displayed `Plugin review cancelled` after Cancel. Neither approved installation.
The parent rechecked the primary Mac session after both reviews and Mac worktree creation.
Its session button still showed `graphics36-stable`.

Independent socket queries found only enabled `rai.lab.validation` in both sessions.
The `commands22` inventory exactly matched its recorded inventory after the phone lifecycle checks.
No plugin preview directories remained under the isolated app's temporary directory.
No preview-directory baseline was recorded. The evidence establishes absence afterward, without identifying individual removed checkouts.
Evidence: `/tmp/rai-named-local43-audit.json`.

### Mac lifecycle fixtures — completed

`Mac Lifecycle 43` uses ID `rai.lab.mac.lifecycle43` on `commands22`.
Its owned manifest is `/private/tmp/rai09-391wxjtr/mac-plugin43/herdr-plugin.toml`.
`Mac Managed 43` uses ID `rai.lab.mac.managed43` on the same socket.
Its owned directory is `/private/tmp/rai09-391wxjtr/config/herdr/plugins/github/rai.lab.mac.managed43-e2f6da8a76ac`.
Both fixtures contain zero actions, build commands, startup commands, and event hooks.
The managed fixture uses synthetic source metadata. It does not establish downloaded installation coverage.
Evidence: `/tmp/rai-mac-plugin43-fixtures.json`.

### Reviewed GitHub installation candidate

The parent authorized an isolated installation of `ogulcancelik/herdr-plugin-examples/dev-layout-bootstrap`.
The reviewed commit is `18709cdc851dd63ed0543eb8388343a5446fd8d8`.
Its manifest has zero build commands, startup commands, and event hooks.
It has one manual Lua action. The validation must not invoke that action.
That action uses Herdr, `ls`, `git`, and `nvim` to create a development layout.
Installation requires Git and Herdr. It does not require executing the manual action dependencies.
The review record includes exact source bytes and SHA-256 hashes.
Evidence: `/tmp/rai-dev-layout43-review.json`.
The following completion record establishes Mac UI installation and removal.


### Mac lifecycle and approved installation completion

Candidate43 Mac canceled unlink and preserved `Mac Lifecycle 43`. Unlink then removed its row and registration.
Its local manifest remained. Managed removal Cancel preserved `Mac Managed 43` and its directory.
Uninstall Managed Files removed that registration and directory. Enabled `rai.lab.validation` remained.

Evidence: `/tmp/rai-mac-plugin43-unlink-cancel.json`, `/tmp/rai-mac-plugin43-managed-cancel.json`, and `/tmp/rai-mac-plugin43-after.json`.

Mac reviewed and installed `dev-layout-bootstrap` at commit `18709cdc851dd63ed0543eb8388343a5446fd8d8`.
The UI showed one manual action and zero build commands, startup commands, and event hooks.
The installed manifest and Lua script hashes matched the review. Git HEAD matched the resolved commit.
No manual action ran. Mac then uninstalled the plugin through its confirmation dialog.
The managed checkout disappeared. Only enabled `rai.lab.validation` remained registered.
The target used the isolated host configuration and the selected `commands22` view.
Herdr shares this plugin registry across local sessions; inventory alone cannot prove session-specific execution.

Evidence: `/tmp/rai-dev-layout43-installed.json` and `/tmp/rai-dev-layout43-uninstalled.json`.

### Phone agent-view configuration and keyboard correction

Candidate44 phone applied label `Codex Ordered43`, agent `codex`, and descending Pane Order.
Panes showed `Prompt37 Accepted` before `Prompt37`. Clear removed the filter and restored the workspace list.
The API snapshot omits agent-view fields. The native pane list established the ordering.

Typing `codex` produced `Codex` in Agent ID. AX value entry supplied lowercase for this check.
Candidate46 disables autocapitalization and autocorrection for identifiers, token values, sources, references, metadata rules, and colors.
Candidate46 typed `codex` directly and retained lowercase. The applied filter showed both Codex fixtures.
The GitHub source and reference also retained their exact typed values.
The temporary filter was cleared afterward.

UI evidence: `/tmp/rai-metadata-plugin44-ui-evidence.json`.

### Candidate46 phone approved installation

The phone reviewed `ogulcancelik/herdr-plugin-examples/dev-layout-bootstrap` at commit `18709cdc851dd63ed0543eb8388343a5446fd8d8`.
Review displayed the exact source, commit, and TOML before installation.
The manifest contained one manual action and no build commands, startup commands, or event hooks.
Install Reviewed Commit succeeded. Installed file hashes and Git HEAD matched the review.
No manual action ran.
Uninstall Managed Files then removed the registration and managed checkout.
Only enabled `rai.lab.validation` remained in the isolated registry.

Evidence: `/tmp/rai-phone-install46-before.json`, `/tmp/rai-phone-install46-installed.json`, and `/tmp/rai-phone-install46-uninstalled.json`.
Typed-input evidence: `/tmp/rai-phone46-typed-input.json`.

### Candidate46 phone notification view reconnect

The phone notification history initially showed no notifications.
The isolated `commands22` API accepted one notification with title `Rai validation notice` and sound `none`.
History then showed exactly one matching title and body `Replay46 owned connection check`.
Done closed the workspace view. Workspace View reopened the same session through the connection menu.
The reopened workspace showed no replay banner. Its notification history showed `No notifications in this connection.`
This check covers closing and reopening a view. It does not establish forced transport reconnect behavior or audible sound.

Evidence: `/tmp/rai-notification46-api.json` and `/tmp/rai-notification46-phone-reopen.json`.

### Notification reply cleanup correction after Candidate46

The review found a missing detach when a host-bound reply rejected newly queued input after temporary attachment.
One cleanup policy now checks temporary ownership, connection generation, and visible pane ownership before detaching.
It covers timeout, disconnect, cancellation, both outbox rejection paths, and successful replies.
Success and outbox rejection await cleanup. Other exits schedule cleanup without extending the reply deadline.
The correction leaves Candidate46 unchanged.

The regression covers temporary attachment, existing ownership, ownership acquired during waiting, and a replacement connection generation.
Each case checks rejection, retained queued input, no notification action, and the expected detach count.
Another regression cancels during frame waiting, with and without a new visible pane owner.
Swift parsing and `git diff --check` passed.
Candidate48 passed 879 Mac tests with six skips and 376 iOS tests, including the stream cleanup regressions.
Both suites reported zero failures. The parent installed Candidate48 on both platforms.
The contract check reported no change and no incompatible callers.
The iOS quality gate still failed against HEAD with 41 findings, including existing branch changes.
Quality evidence: `/tmp/rai-reply-cleanup-quality.json`.

### Candidate46 notification reconnect completion

The themes agent verified Mac view close and reopen with `REPLAY47 A`.
History changed from one notice to zero after reopening.
A socket relay then disconnected only the selected Mac and phone native endpoint connections.
Both views displayed `Herdr closed the socket`. Reconnect restored both views and cleared their histories.
`REPLAY47 C` then appeared once on each app. Earlier notices did not return.
The relay restored the original socket inode. The `commands22` server did not stop.

Historical notices can remain while a view reports failure. Reconnect clears them.
This test interrupted the native endpoint socket. The phone WebSocket stayed connected.
Earlier `recovery31-checks.json` covers phone WebSocket recovery after an owned Mac restart, without notification counts.
No audible output was tested. All replay fixtures used sound `none`.
Evidence: `/private/tmp/rai09-391wxjtr/notify47-ui-results.json`.

### Candidate50 audit rejection correction

Plugin audit events now keep the endpoint request ID and record the plugin UUID as `plugin_request_id`.
The phone converts matching audit errors into plugin results and stops progress indicators.
The failed view keeps its error until reopening. Late state cannot erase that error.
Reopening creates a new view identity and starts its sequence at one. Rejected requests do not replay.

The new regression covers `BridgeConnection.handle`, plugin error delivery, pending progress, old errors, and a successful request after reopening.
Swift parsing and `git diff --check` passed. Frozen Candidate50 execution remains assigned to the parent.
Ripwire reports existing branch findings against HEAD, including audit constructor size and duplicate constructors.
It also flags the recovery test class size and XCTest methods as new symbols. The quality gate did not pass.
Quality evidence: `/tmp/rai09-audit50-quality.json`.

## Native plugin-pane launch boundary

Plugin66 adds shared Mac and iOS Open controls for each valid declared plugin pane.
The controls require an enabled plugin and the advertised native `plugin.pane.open` method.
Unsupported hosts show: “This Herdr version cannot open plugin panes in this view.”

Herdr source at `4b5e9bd` omits plugin-pane lifecycle methods from `src/server/client_commands.rs`.
Its `command.invoke` route accepts registered custom commands; declared plugin panes do not create those commands.
Thus, current Herdr cannot launch declared panes through Rai's native client connection.
Rai does not use the generic API as a fallback because its popup state follows global focus.

If a host advertises `plugin.pane.open`, Rai sends the request through the owning native client connection.
The request includes only `plugin_id`, `entrypoint`, and `focus: true`.
Herdr keeps the declared placement and rejects explicit target parameters for popup placement.
Rai captures the selected workspace, tab, pane, boot, and projection before launching.
The native actor rejects changed selection before writing and does not replay the request after reconnect.
Herdr refreshes the installed manifest and rejects disabled plugins and undeclared entrypoints.

Plugin66 focused Mac validation ran 46 tests with zero failures and one existing live-lab skip.
The tests cover declared entries, disabled plugins, advertised capability, native connection ownership, popup parameters, and bridge audit fields.
Final Codex review returned no findings and exit 0.
See `/private/tmp/rai09-391wxjtr/plugin66-validation.json` for source hashes and current iOS validation status.
Current-host pane launch remains unavailable until Herdr advertises the native method.
