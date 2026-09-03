# macOS ↔ iOS parity — audit & backlog

What the Mac app exposes versus what the iOS companion exposes over the
bridge, and what *should* exist on the phone. The phone is deliberately a
**remote for the herd**, not a full terminal multiplexer — parity means
"everything you'd want while away from the Mac", not a 1:1 clone of a
30-inch-display UI.

Audited 2026-09-02 against `main` (bridge protocol v6).

## Parity matrix

| Capability | macOS | iOS | Verdict |
| --- | --- | --- | --- |
| Live herd (spaces → tabs → panes, statuses) | sidebar | list + "Needs you" section | ✅ parity |
| Herd before connection | current in-memory snapshot | saved snapshot with `last seen HH:MM` | ✅ phone offline support |
| Connection diagnosis | Mac connection state | cause, action, raw details, sync age | ✅ phone remote support |
| Live terminal (view, type, control keys) | full SwiftTerm pane | streamed 80-col SwiftTerm + compose bar | ✅ parity |
| Scrollback search | ⌘F find bar | find bar with match count | ✅ parity |
| Send image to agent | paste screenshot | photo picker → temp file path | ✅ parity |
| Launch agent (claude/codex) | split-and-launch, palette | launcher sheet: agent + workspace + optional directory | ✅ parity |
| Rename / close tab & pane | context menus | context menus + confirm | ✅ parity |
| Focus pane in herdr | click | `selectPane` on open | ✅ parity |
| Claude prompt controls | native terminal | permission, trust, plan, and AskUserQuestion blocks | ✅ phone support |
| Notifications on blocked/done | native macOS + dock badge | APNs bursts, workspace groups, actions, retraction, tap-to-open | ✅ parity (physical delivery not verified) |
| Session name visibility | title bar / switcher | connection menu ("Session: …") | ✅ display-only |
| Rename / close **workspace** | context menu | — | ⚠️ gap: needs `renameWorkspace` / `closeWorkspace` bridge messages |
| Broadcast input to all panes in tab | toolbar action | — | ⚠️ gap: needs `broadcastInput` bridge message |
| Reorder tabs / spaces | drag | — | ⏸ skip: low value on phone, high UI cost |
| Split panes / zoom / drag dividers | full layout engine | — | ⏸ skip: pane layout is a desktop concern; phone shows one pane at a time |
| Session switcher (named/remote sessions) | Phase-4 switcher | connection-menu picker (build 20) | ✅ parity |
| Worktree create/open | sidebar + palette | — | ⏸ defer: needs worktree list + create over bridge; revisit after workspace ops |
| Settings (fonts, plugins, integrations, server ops) | full settings window | — | ⏸ skip: Mac-admin concerns; phone stays thin |
| Command palette | ⌘K | — | ⏸ skip: the herd list *is* the palette at phone scale |

## Mac side LANDED (2026-07-28, feat/bridge-parity) — phone UI now unblocked

All additive, no version bump (old phones skip unknown message types):

- `renameWorkspace {workspaceID, label}` / `closeWorkspace {workspaceID}`
  (client→server) → applied directly; confirm destructive intent phone-side.
- `broadcastInput {tabID, text}` (client→server) → sends text+Enter to every
  pane in the tab.
- `listSessions` (client→server) → replies `sessions` with
  `[{name, is_running, is_current}]`; `selectSession {name}` switches the
  herd the Mac (and phone) watches.
- `backgroundWork` (server→client, pushed on refresh ~10s):
  `{type:"backgroundWork", work:[{pane_id, summaries:[String]}]}` — the
  pane's pending shells/monitors/subagents/workflows as kind-labeled
  human summaries (e.g. `[monitor] merge-queue watch`). Panes absent from
  the list have no pending work. **Phone UI wanted:** ⏳ badge + count on
  the pane row, summaries in a detail view — a waiting agent must not
  read as plain Idle.
- Mac notifications now use stable per-pane identifiers and are RETRACTED
  when a pane changes, closes, or is selected on the Mac.

## Push intelligence LANDED (2026-09-02)

- The presence gate has one worker for presence checks and a 15-second burst
  window. Bursts become one triage push. Single pushes keep pane actions.
- APNs alert payloads group by workspace with `thread-id`, `summary-arg`, and
  `summary-arg-count`. Cross-workspace bursts use the `rai-triage` thread.
- Alert payloads carry shared `agent-<paneID>` values and creation timestamps.
  Mac retraction sends identifiers with a cutoff timestamp.
- iOS removes matching older notifications and keeps newer replacements.
  Badge recomputation excludes alerts seen during the last app activation.
- Background retraction is additive. Old phones ignore the custom payload.
- Settings → iPhone now has per-device test results and a read-only Doctor.
- APNs work uses one queue per device. A stalled device does not delay another device.
- Snapshot pane objects include an optional Claude hook `beacon` value.
  AskUserQuestion blocks use its labels and descriptions before grid text.
- A beacon can include an optional `request_id` for one prompt instance.
- The beacon field is additive within protocol v6. It does not require another bump.

## Structured prompt controls LANDED (2026-09-03)

- AskUserQuestion blocks show steps, descriptions, checkboxes, free text, and Submit.
- Hook beacon questions supply labels. The live grid supplies state and key proof.
- Unnumbered trust and confirm dialogs use verified arrow movement before Enter.
- Numbered permission dialogs keep their prior digit-only action.
- Each structured action stops after four seconds or an unexpected grid change.
- Each tap stays bound to its rendered signature, prompt instance, beacon request, and question.
- Older beacons use a per-pane prompt instance counter.
- Next sends Tab. Previous sends Left. Enter only confirms an option or Submit.
- Checkbox retries wait for a newer grid frame and confirm the wanted state.
- Controls require a Claude pane or a beacon.
- Quoted dialogs above a live composer do not create controls.
- Unknown hookless wizard steps disable step navigation.
- The raw terminal remains available for unknown dialog forms.
- Plan approval follows its documented shape. No real plan capture verified this grammar.
- The optional beacon `request_id` is additive and keeps protocol version 6.

## Backlog (value order)

1. **Workspace ops over the bridge** — `renameWorkspace` / `closeWorkspace`
   messages + Mac `RaiModel` counterparts (`renameWorkspaceFromBridge`,
   `closeWorkspaceFromBridge`), then context menus on the workspace headers in
   `MonitorView`. Bump `bridgeProtocolVersion` only if messages must be
   understood by older Macs (new client→server messages are safe: unknown
   types error per-message on the Mac, and the phone's tolerant decoder skips
   unknown replies).
2. **Broadcast input** — `broadcastInput(tabID:bytesBase64:)` bridging to
   `RaiModel.broadcast(text:)`; a "send to all panes in this tab" toggle on
   the compose bar.
3. **Session follow** — surface `listSessions` + `selectSession` so the phone
   can switch the herd it watches when the Mac runs named sessions.

Items 1–2 require Mac-side changes — coordinate with whoever owns
`Sources/RaiApp` at the time (the bridge server and `RaiModel` are shared
surface).

## Protocol-drift guardrails (learned the hard way)

Protocol version 6 replaces the shared token with per-device credentials. The
new `pair` message sends a short code, protocol version, and device data. The
`paired` reply returns one device credential once. The phone confirms it with
`hello`. A lost reply can retry the code until expiry. Later connections also
use `hello`.

This change is not compatible with protocol version 5. Old phones receive
"Re-pair required" and must pair again.

- The iOS client **skips** messages it cannot decode (see
  `BridgeConnection.receiveMessages`) instead of tearing down the socket —
  before this, one unknown/changed message put the app in a permanent
  reconnect loop. Keep it that way when adding messages.
- True incompatibility is expressed by bumping `bridgeProtocolVersion` in
  `Sources/RaiCore/Bridge/BridgeProtocol.swift`; the welcome check stops and
  asks the user to update Rai without clearing the pairing.
- A dev Mac app (rebuilt from a feature branch) and a released phone build
  routinely coexist — additive protocol changes only, or version-gate.
- The current Mac reports a missing herd as `Herdr is not connected.`
  The phone maps this existing error, so offline resilience needs no protocol change.
- APNs custom keys are additive. Old iOS builds ignore new push fields.
