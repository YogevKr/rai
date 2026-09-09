# Herdr 0.9 support on macOS and iOS

Date: 2026-09-09.

Status: Yogev selected every release feature for both platforms, then excluded Muse-specific work on 2026-09-08.
This document defines the implementation scope. Existing Muse fixture results remain historical evidence.

Implementation includes isolation, startup recovery, lazy file-access help, scroll indicators, event synchronization, capabilities, and group closure.
Muse launch works on both platforms. Client updates retain compatible executables for existing servers.
Both platforms expose status explanation, client update, and live handoff controls.
Phone management confirms the target, rejects stale identities, and records writes through the Mac audit gate.
Phone pane observation preserves Mac selection and server geometry on capable hosts. Legacy hosts retain shared selection.
Native generation-one transport now drives additional Mac windows, with separate snapshots, surfaces, selection, and request ownership.
Those windows route tab, pane, and workspace menus through their endpoint. Clipboard input uses semantic paste events.
Input writes have deadlines. Reconnect clears rendering caches. Startup blocks actions until surface activation finishes.
Control keys use semantic events. Input survives metadata revisions and stops when navigation changes its target.
The primary Mac window and phone observation view retain their previous terminal paths.
The phone also offers a separate Workspace View through the authenticated Mac bridge.
Each phone view owns its endpoint identity, ordered requests, input queue, and terminal surface.
Both phone terminal views provide captured text selection and web-link taps.
Native endpoint views add history menu controls and temporary translucent scrollbar overlays.
They also render bounded image scenes and provide captured image inspection. Phone updates retain unchanged image data.
Both native views expose command lists and news. Commands preserve captured targets and reject changed ownership.
Both views render popup terminals and images. Popup input preserves terminal identity and does not reach the underlying pane.
Both views offer local System, Light, and Dark appearance, plus Always, Auto, and Off pane borders.
Phone views recover after host reconnect and app suspension. Recovery clears queued input and uses a new view identity.
Closed phone views remain closed. Mac windows keep separate appearance and border choices.
New Mac windows use the last saved choices. Theme import and palette overrides now have shared implementations.
Both platforms expose machine management, metadata rules, themes, plugins, notifications, worktrees, retained history, and atomic prompts.
Machine notifications carry machine and boot identity. They open their target without permission approval actions.
Upstream provides no verified permission nonce for these machine notifications.
The integration checks found theme rendering, sheet presentation, mouse, scrolling, and worktree navigation defects.
Candidate63 includes these corrections, machine activation fixes, repeated-close protection, identifier keyboard settings, and history range validation.
The corrected Mac source passed 941 tests. Unchanged iOS source passed 407 tests. Seven Mac tests skipped; no tests failed.
App checks are closed within the recorded limits. Corrected Mac startup, installation recovery, and paired-phone recovery checks passed.
Static quality reports remain non-clean.
Herdr shares history position across views of one pane. The integrated validation document records the completed phone scrolling checks.
The missing-Herdr process correction resolves the reproduced crash locally. Final CI and publication checks remain required.
Semantic surfaces preserve OSC 8 links and reject terminal control bytes in link targets.
Remaining feature and platform checks appear in the end-to-end evidence document.
See the [integrated validation checkpoint](herdr-09-integrated-validation.md) for current results and limitations.

## Scope

Support every product feature in Herdr 0.9.0 on macOS and iOS, except Muse-specific work.
Give both platforms the same operations, with controls that fit each device.
Complete each phase on both platforms before marking that phase complete.
Every feature requires an end-to-end pass in isolated macOS and iOS app instances.
Unit tests, protocol tests, and compilation do not replace this requirement.
Record scenarios and evidence in the [isolated end-to-end test plan](herdr-0.9-e2e.md).

The previous audits contain historical exclusions for phone features. Those exclusions do not apply to this release plan.
Server fixes require verification. They do not each require a new Rai control.
Windows, Wayland, Nix, and Termux installer changes remain upstream platform work.
Their release coverage appears in the verification section below.

Keep the existing iOS connection through the Mac bridge.
The Mac manages Herdr connections. Each Mac window and connected phone receives a separate client view.
This preserves the current pairing model while allowing independent machine, workspace, tab, and pane selection.

## Evidence

The installed binary and server report Herdr 0.8.2, protocol 20.
The tagged 0.9.0 API schema reports protocol 22, with 102 methods versus 91 in the installed schema.
The schema removes no methods. It adds eleven methods and new capability fields.

The stable endpoint uses generation 1. Its generation differs from the private protocol version.
Direct terminal attachments retain the private protocol contract.
Rai currently uses these attachments for Mac terminals and terminal observation for phone streams.

Relevant current code:

| Area | Current implementation | Required change |
| --- | --- | --- |
| Initial state | `RaiModel.connect` takes a snapshot before subscribing. | Subscribe and acknowledge before the authoritative snapshot. |
| Event connection | `HerdrClient.events` discards subscription acknowledgements. | Expose readiness and buffer events during initialization. |
| Server selection | `RaiModel.connect` tears down the previous connection. | Keep independent endpoint connections. |
| Phone selection | `RaiBridgeServer` routes `selectSession` through the shared Mac model. | Keep selection within the requesting device view. |
| Terminals | `TerminalPool` launches `terminal attach --takeover`. | Add a stable endpoint path and test size ownership. |
| Bridge identity | Most messages identify resources with bare pane, tab, or workspace IDs. | Include endpoint and view identity. |
| Phone cache | `TerminalCacheKey` includes a connection scope and agent identity. | Extend it with endpoint and server boot identity. |
| Updates | Client updates and confirmed handoffs use separate controls. Existing servers use retained compatible clients. | Add phone administration controls. |
| Agent controls | `AgentLaunchKind` includes Muse. Isolated Mac and phone launch checks passed. | Complete status explanation and lifecycle checks. |
| Phone transport | Bridge protocol 6 already supports capability announcements from devices. | Add negotiated endpoint and view operations. |

The existing parity documents are historical evidence, not a current implementation inventory.
For example, current phone code already exposes workspace rename and close actions.

## Shared architecture

Separate connection state from presentation state.
Use these proposed boundaries in `RaiCore` and the Mac host:

| Boundary | Responsibility |
| --- | --- |
| Endpoint identity | Identify the machine profile and Herdr session. Labels must not determine identity. |
| Endpoint connection | Own transport, capabilities, server boot identity, resources, health, and reconnect state. |
| Client view | Own selection, terminal size, active surface, copy state, and presentation delivery for one window or device. |
| Resource reference | Combine endpoint identity with a workspace, tab, pane, or agent identifier. |
| Action request | Carry resource identity, client view, request identity, and expected server generation. |
| Presentation model | Carry metadata, themes, images, menus, agent views, and notifications without platform view classes. |

Extend existing models and transport helpers where their contracts fit.
Do not put all endpoint state into the current singleton `RaiModel`.
Keep AppKit and UIKit rendering outside shared protocol code.

Use one metadata connection per endpoint where the upstream contract permits sharing.
Use separate client endpoint sessions for independent views where Herdr requires separate connections.
Verify this connection arrangement before implementing terminal rendering.

Keep three version contracts separate: Herdr API protocol, Herdr endpoint generation, and Rai bridge protocol.
Discover supported operations from the selected server and negotiate phone features separately.
Unknown optional fields must not break a connection.

Carry endpoint identity through snapshots, frames, history, permission requests, push actions, errors, and cache entries.
Include server boot identity where requests or retained content can become stale after replacement.
Reject stale writes. Do not replay terminal input or completed actions after reconnecting.

Add capability-gated bridge messages without changing the meaning of existing protocol 6 messages.
Keep legacy messages limited to the existing single-endpoint behavior.
If safe coexistence requires a bridge version change, preserve pairing and report the required app update.

## Feature contract

| Feature | macOS | iOS | Shared behavior |
| --- | --- | --- | --- |
| Multiple machines | Machine groups in the sidebar and machine management in Settings. | Machine picker, grouped agents, and machine management sheets. | Local and saved SSH profiles; named sessions; separate health and reconnect state. |
| Machine operations | Add, rename, enable, disable, and remove. | The same actions through the Mac host. | Show setup prompts interactively. Never install or replace a server during background reconnect. |
| Combined agents | Filter and search across connected machines. | Search, filter, and open agents across connected machines. | Display machine identity and keep disconnected records visibly stale. |
| Independent views | Each window selects its own workspace and tab. | Each phone selects its own machine, workspace, tab, and pane. | Navigation must not change another view's selection. |
| Shared-tab sizing | Respect the last interacting client on a shared tab. | Support independent control and a read-only observation mode. | Different tabs fit their viewers. Observation alone must not resize a running pane. |
| Capability compatibility | Disable unsupported actions with a reason. | Receive capability state and show the same limitation. | Version differences alone must not trigger server replacement. |
| Client presentation | Keep menus, theme, selection, and copy state within each window. | Keep equivalent state within the phone view. | Use the stable endpoint contract for supported presentation operations. |
| Muse | Excluded from remaining scope by Yogev. | Excluded from remaining scope by Yogev. | Preserve completed code and historical fixture evidence. No real Muse setup is required. |
| Conditional sidebar styles | Configure ordered text and numeric rules. | Configure the same rules in a settings sheet. | Share rule evaluation, token meanings, precedence, and validation. |
| Light and dark themes | Follow macOS appearance or select an explicit mode. | Follow iOS appearance or select an explicit mode. | Support separate light and dark overrides. Import supported Herdr theme values. |
| Pane borders | Offer Always, Auto, and Off. | Offer the same options in terminal appearance settings. | Preserve old boolean configuration meanings when importing settings. |
| Pane graphics | Render images at their pane positions. | Render images and provide a touch inspection view. | Handle replacement, clipping, scroll, resize, deletion, and limits. Respect `terminal.kitty_graphics` and its legacy alias. |
| Workspace group closure | Separate workspace and group actions with an affected-workspace preview. | Show the same preview and explicit group action. | Close only confirmed members. Reject stale connection identity and membership. |
| Worktree behavior | Preserve focus during background removal. Offer trust for one request. | Expose worktree list, create, open, remove, and the same trust choice. | Keep repository trust within one request. Use the selected endpoint's paths. |
| Event delivery | Keep the model current during startup and reconnect. | Receive consistent initial state and subsequent events. | Subscribe, acknowledge, buffer, snapshot, then reconcile buffered events in order. |
| Scrollback and selection | Preserve selection while output continues; copy without interrupting the agent. | Preserve touch selection and support hardware keyboard copying. | Retain history and reject stale content revisions. Verify recent reads include the viewport. |
| Keyboard, mouse, and paste | Preserve composed keys, pixel mouse coordinates, and multiline paste boundaries. | Support touch controls, external keyboards, pointers, and multiline paste. | Use semantic input where available. Preserve raw input for interactive terminal applications. |
| Prompt submission | Submit composed prompts through Herdr's atomic prompt operation. | Use the same operation from the phone composer. | Track delivery errors and terminal exit. Do not replace raw-key permission controls with prompt submission. |
| Plugins and commands | Show commands, popups, notifications, titles, and filtered agent views. | Show equivalent commands, sheets, notifications, view labels, and agent lists. | Use endpoint presentation state. Verify routing and delivery before replacing existing notification logic. |
| Plugin links | Route matching terminal links to the owning plugin. | Route taps through the same endpoint action. | Use pane and content identity. Keep ordinary file handling distinct from plugin handling. |
| Updates and news | Separate client update, server replacement, and optional handoff. Show release notes. | Show host and server status, news, and supported management actions. | Report the exact target and effects. Keep handoff optional. Preserve agents during compatible client updates. |
| Persistent sessions | Attach to background servers and detach without stopping agents. | Disconnect or suspend the phone view without stopping agents. | Remove assumptions about `--no-session`. Keep server stop explicit. |

Use native platform controls with the same operation semantics.
For example, Mac drag controls can have phone menu equivalents for move, reorder, split, resize, and zoom operations.
Keep these operations available when they form part of machine and workspace navigation.

## Build order and acceptance

### Prerequisite: Verify app isolation

Build and verify the isolation setup before implementing Phase 1.
Isolate app data, preferences, credentials, caches, sockets, bridge ports, simulator storage, and Herdr sessions.
The current development bundle shares application data with the release bundle. A different app name does not establish isolation.
The existing Herdr lab isolates named sessions. It does not establish complete app isolation.
Follow the [isolation contract and feature scenarios](herdr-0.9-e2e.md).

Run each feature's isolated app tests during its implementation phase.
Fix failures and repeat affected scenarios before continuing to the next phase.
Phase 7 repeats the combined workflows and verifies the final build.

### Confirmed group closure

Herdr 0.9 cannot atomically compare expected group membership with a group closure request.
Rai closes confirmed linked workspaces individually, then closes the primary workspace.
Every request sends `close_group: false`. Herdr rejects primary closure if another group member remains.
This prevents a concurrently created member from closing without review.
Rai rejects groups containing multiple primary workspaces before sending any closure request.
An error after partial closure reports the completed count and requires another review.
The confirmation explains partial completion. Connection changes invalidate existing confirmations.

### Compatible client retention

Before updating the installation, Rai copies a compatible client into its own application data.
It checks the copied client's embedded API schema before allowing the update.
Mac attachments, restarted cached terminals, CLI actions, and phone observers use the retained executable.
New server launches, installation management, and handoffs use the installation.
Retained clients survive app restarts. They do not establish stable endpoint transport support.

### Phase 1: Compatibility and event correctness

Change `HerdrClient`, `HerdrModels`, `RaiModel`, and the bridge capability contract.
Fix initialization and reconnect ordering, including subscription readiness and event buffering.
Handle pane filters when the pane set changes.
Add explicit group closure to Mac and phone controls.
Separate update actions and expose server capabilities.
Muse-specific work is excluded. General agent explanation and control checks remain in scope.

Extend `HerdrModelsTests`, `StructuralEventTests`, `BridgeProtocolTests`, and phone `BridgeErrorPolicyTests`.
Add a deterministic socket test that changes state between subscription acknowledgement and snapshot completion.
Repeat the test after reconnecting and while creating a new pane.
Pass mixed 0.8.2 and 0.9.0 fixture checks without silently dropping unsupported actions.

### Phase 2: Stable endpoint transport and independent views

Implement the endpoint handshake, advertised codecs, framing, capability checks, server boot identity, and revision handling.
Evaluate terminal surface decoding against the existing SwiftTerm views.
Keep the existing transport during this evaluation. Do not claim stable compatibility for private terminal attachments.

Add client view state to the Mac window model and `BridgeClient`.
Route phone selection through its own view instead of the shared `RaiModel` selection.
Extend `TerminalPool`, bridge streaming, phone `BridgeConnection`, and terminal cache identity.

Verify two Mac windows, one phone, and a Herdr TUI on one isolated server.
Each viewer must navigate independently. Different tabs must fit their viewers.
Shared-tab interaction must follow Herdr's size policy without repeated resize loops.
Phone observation, disconnect, rotation, and suspension must preserve other viewers' selection and usable geometry.
Test copy state and popup input isolation between views.

### Phase 3: Multiple machines and notification identity

Extract endpoint ownership from `RaiModel.connect` and reuse `RemoteConnection` where its transport contract remains valid.
Read supported machine profiles through Herdr's machine interface. Verify any profile mutation against the selected host.
Add the Mac machine sidebar and phone machine picker.
Wire machine management, named sessions, health probes, bounded reconnect, and stale-state presentation.

Extend resource identity throughout terminal streams, history, pending decisions, and APNs payloads.
Extend `BridgeProtocolTests`, `RemoteConnectionTests`, bridge socket tests, terminal cache tests, and push identity tests.
Use two isolated endpoints that both contain `w1:p1`.
Prove that input, closure, history, and notification actions reach only the intended endpoint.
Disconnect one endpoint during input on another. The connected endpoint must continue working.
Keep stale panes noninteractive until fresh state and a matching frame arrive.

### Phase 4: Terminal images and interaction

Add shared image identity and placement models, bounded image transport, and native image rendering on both platforms.
Preserve graphics ownership between views. Retire assets after replacement, deletion, or server restart.
Extend selection, copy, scrollback, links, paste, keyboard, mouse, and composed prompt behavior.
Hide pane scroll indicators while idle. Show partially transparent overlays only during user scrolling.
Indicator visibility must not change terminal size, content layout, or rendering geometry on either platform.
Expose keyboard copy motions and scrollback search through phone controls and hardware shortcuts.
Expose scrollback export through native save and share controls; keep server editor actions available through commands.

Extend terminal output, link, history, layout, and phone full-frame tests.
Test an oversized image beside a small image, image replacement, reconnect, and retained content after rotation.
Test selection during continuous output and copy failure without sending an interrupt to the agent.
Test multiline paste and terminal exit during prompt submission.
Measure retained history and memory under the same workload before and after the transport change.

### Phase 5: Presentation rules, themes, and borders

Add a shared rule evaluator and theme values in `RaiCore`.
Wire Mac sidebar and settings controls, plus phone monitor and appearance settings.
Use client-local preferences by default. Import Herdr settings explicitly without changing another client's settings.
Expose all supported metadata tokens and provide rule previews on both platforms.

Test ordered text and numeric rules, absent metadata, invalid rules, and unsupported token values.
Verify light and dark overrides, automatic switching, and Always, Auto, and Off borders.
Check readable status information when color is unavailable, with large text and VoiceOver enabled.

### Phase 6: Commands, plugins, and administration

Consume endpoint command, popup, agent-view, release-note, and presentation data.
Extend existing Mac plugin and server controls through typed bridge operations.
Add phone command search, plugin management, integrations, worktree management, news, and server administration sheets.
Preserve remote execution context for commands, paths, and plugin links.
Do not forward unrestricted shell execution as a substitute for each supported management operation.

Verify notification routing, duplicate suppression, sounds, titles, popup focus, command failures, and agent-view ordering.
Verify explicit target selection for installation, repository trust, group closure, server replacement, and server stop.
Verify cancellation at each interactive setup prompt without an unintended server change.
Test handoff only on servers created for the test.

### Phase 7: Full release verification

Run the repository Mac test gate and the iOS simulator gate from `TESTING.md`.
Use an isolated Herdr 0.9.0 binary and named test servers.
Keep the installed server and active agents outside test targets.

Verify every feature row on both platforms and record evidence per row.
Require passing app-level evidence for each scenario in `herdr-0.9-e2e.md`.
Each result must identify the tested commit, app build, Herdr version, isolated targets, and observed outcome.
Run mixed app-version tests for negotiated bridge features and update guidance.
Run physical iPhone checks for push actions, image paste, touch selection, suspension, and external input devices.
Use the isolated simulator for current software verification. Physical-device checks are deferred and remain unverified.
Record unavailable hardware checks as unverified. Do not count simulator results as physical-device evidence.
An unverified required scenario keeps its feature incomplete.

## Release fix coverage

Use the tagged release notes as the complete checklist. Track each bullet in one of these verification groups.

| Release fix group | Verification in Rai |
| --- | --- |
| Clipboard, selection, key layouts, mouse, and multiline paste | Verify native Mac and phone behavior through the selected transport. |
| Image limits, replacement, and graphics ownership | Verify both native renderers and independent client views. |
| Handoff, shutdown persistence, and SSH detach | Use isolated processes; prove detach preserves sessions and explicit replacement reports its effects. |
| Sidebar visibility and background worktree removal | Verify selected rows remain visible and unrelated views keep their selection. |
| Repository trust and foreground working directory | Verify one-request trust and correct endpoint paths for new panes and worktrees. |
| Prompt submission, wait transitions, and terminal exit | Verify atomic delivery, error reporting, and no replay after reconnect. |
| Recent reads and idle scrollback memory | Verify viewport inclusion, retained history, and measured memory under a fixed workload. |
| Agent status, session persistence, and detection manifests | Use fixtures for Muse, Claude, Codex, Cursor, Copilot, OMP, and OpenCode transitions. |
| CLI argument parsing and structured errors | Verify arguments sent by Rai and preserve structured failures in both interfaces. |
| Git ref failures and tab status output | Verify stale-data handling, bounded refresh, and plain display without escape fragments. |
| Plugin paths, working directory, and OSC 8 file links | Verify commands and link actions on their owning endpoint. |
| Windows input, agents, hooks, installation, and WSL clipboard | Record upstream coverage. Do not claim unsupported Windows machine connections. |
| Wayland clipboard, Nix downloads, and Termux rejection | Record upstream coverage; these do not run inside the Mac or iOS applications. |

## Risks and decision rules

The stable endpoint path is the largest technical uncertainty.
Isolated checks demonstrate native text, phone transport, graphics, popups, layout, and closure on both platforms.
The integrated validation record identifies remaining scenario checks and tool limits.
If a contract gap prevents a feature, document the missing operation and retain that feature in scope.

Multiple machines affect identity across most bridge operations. Migrate identity before enabling cross-machine actions.
Notifications and permission decisions require the same identity migration as terminal input.

Ripwire's graph reports ambiguous Swift calls and misses test classifications in this repository.
Use its map to locate code. Use actual test files and runtime evidence to establish coverage.

No phase is complete from compilation alone.
No feature is complete until its required isolated macOS and iOS end-to-end scenarios pass.
The final acceptance condition requires all feature rows on macOS and iOS, with explicit evidence for remaining platform limits.

## Sources

- [Herdr 0.9.0 release notes](https://github.com/herdrdev/herdr/releases/tag/v0.9.0)
- [Tagged API schema](https://github.com/herdrdev/herdr/blob/v0.9.0/docs/next/api/herdr-api.schema.json)
- [Tagged event initialization guidance](https://github.com/herdrdev/herdr/blob/v0.9.0/docs/next/website/src/content/docs/socket-api.mdx)
- [Tagged machine connection contract](https://github.com/herdrdev/herdr/blob/v0.9.0/docs/next/website/src/content/docs/connecting-machines.mdx)
- [Stable endpoint contract](https://github.com/herdrdev/herdr/blob/v0.9.0/src/protocol/endpoint.rs)
- [Handshake and direct attachment distinction](https://github.com/herdrdev/herdr/blob/v0.9.0/src/client/handshake.rs)
- [Client snapshot and presentation messages](https://github.com/herdrdev/herdr/blob/v0.9.0/src/protocol/wire.rs)
- [Repository test workflow](TESTING.md)
