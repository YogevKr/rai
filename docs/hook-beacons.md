# Claude Code hook beacons

This document records the hook research for Rai beacon support.

The first research used Claude Code 2.1.258 on 2026-09-02.

The decision check used Claude Code 2.1.259 on 2026-09-03.

Sources:

- [Claude Code hooks reference](https://code.claude.com/docs/en/hooks)
- [Claude Code hooks guide](https://code.claude.com/docs/en/hooks-guide)
- [Herdr CLI reference](https://herdr.dev/docs/cli-reference/)
- [Herdr socket API](https://herdr.dev/docs/socket-api/)
- [Herdr integrations](https://herdr.dev/docs/integrations/)

## Empirical probe

The probe used a new directory under `/tmp`.

It passed a separate settings file through `claude -p --settings`.

It disabled user, project, and local setting sources.

Each test hook copied its stdin JSON to one temporary JSONL file.

A `Write` request caused a headless permission denial under manual mode.

The run emitted `SessionStart`, `UserPromptSubmit`, `PreToolUse`, and `Stop`.

The run did not emit `PermissionRequest` or `Notification`.

The installed binary contains `PermissionRequest` and `executePermissionRequestHooks`.

This confirms event support in version 2.1.258.

However, version 2.1.258 did not emit it for this headless denial.

Rai therefore installs `PreToolUse` as a compatibility source.

An ordinary `PreToolUse` supplies tool context but is not pending by itself.

`PermissionRequest` or `Notification.permission_prompt` makes that context actionable.

The probe could not load `AskUserQuestion` in print mode.

Its input shape remains documentation-backed, not probe-backed.

### Interactive decision check

The decision check ran Claude in an isolated herdr lab pane.

It used a temporary settings file and a fake Unix socket server.

The socket path stayed below macOS's 104-byte Unix path limit.

The fake server returned `allow` for `touch allow-created`.

Claude ran the command without a permission dialog.

Claude showed `Allowed by PermissionRequest hook` after the command.

The fake server then returned `none` for `touch none-created`.

Claude showed its normal four-choice permission dialog.

The second command did not run.

## Event input

All listed events include `session_id`, `transcript_path`, and `cwd`.

Some events also include `permission_mode`, `prompt_id`, and `effort`.

The reference marks these fields as event-dependent.

| Event | Event fields | Evidence |
| --- | --- | --- |
| `PermissionRequest` | `tool_name`, `tool_input`, optional `permission_suggestions`; no `tool_use_id` | Current reference. The installed probe did not emit this event. |
| `PreToolUse` | `tool_name`, `tool_input`, `tool_use_id` | Reference and probe. The probe captured `Bash` and `Write` objects. |
| `PreToolUse:AskUserQuestion` | `tool_input.questions[]`; each item has `question`, `header`, `options[]`, and `multiSelect` | Current reference. Print mode did not expose this tool. |
| `Notification` | `message`, optional `title`, `notification_type` | Current reference only. |
| `Stop` | `stop_hook_active`, `last_assistant_message`, `background_tasks`, `session_crons` | Reference and probe. It carries final text, not only `transcript_path`. |
| `UserPromptSubmit` | `prompt` | Reference and probe. |
| `SessionStart` | `source`; optional `model`, `agent_type`, and `session_title` | Reference and probe. The probe reported `source: startup`. |

The guide lists these `Notification` values:

- `permission_prompt`
- `idle_prompt`
- `auth_success`
- `elicitation_dialog`
- `elicitation_url_dialog`
- `elicitation_complete`
- `elicitation_response`
- `agent_needs_input`
- `agent_completed`
- `quota_auto_resume_fired`
- `quota_auto_resume_stale`
- `quota_auto_resume_disabled`

The guide says `permission_prompt` waits about six seconds in terminal sessions.

An earlier permission answer prevents that notification.

The short headless probe denied the tool before this delay.

## Probe payload shapes

The probe captured this `PreToolUse` shape:

```json
{
  "session_id": "<uuid>",
  "transcript_path": "<path>.jsonl",
  "cwd": "/private/tmp/<probe>",
  "prompt_id": "<uuid>",
  "permission_mode": "default",
  "effort": {"level": "high"},
  "hook_event_name": "PreToolUse",
  "tool_name": "Write",
  "tool_input": {"file_path": "<path>", "content": "rai-hook-probe\n"},
  "tool_use_id": "toolu_<id>"
}
```

The probe captured this `Stop` shape:

```json
{
  "session_id": "<uuid>",
  "transcript_path": "<path>.jsonl",
  "cwd": "/private/tmp/<probe>",
  "hook_event_name": "Stop",
  "stop_hook_active": false,
  "last_assistant_message": "<final response>",
  "background_tasks": [],
  "session_crons": []
}
```

## Pane correlation

Herdr documents `HERDR_PANE_ID` and `HERDR_SOCKET_PATH` for managed pane processes.

Herdr injects both variables when it starts each pane process.

Read-only CLI checks confirmed that `herdr` exposes the `pane` command.

`herdr pane process-info --help` accepts `--pane <ID>` or `--current`.

The socket API documents the response fields used here.

They include the shell PID, foreground process group, process PIDs, arguments, and cwd.

Rai's `HerdrServerLaunch` selects server arguments but does not add pane variables.

`HerdrClient` accepts an explicit socket or expands `HERDR_SOCKET_PATH` by default.

The hook forwards `HERDR_SOCKET_PATH` when its value is safe for direct JSON insertion.

Rai rejects a beacon when that socket path differs from the active Herdr socket.

Rai uses the supplied pane ID when the current snapshot contains it.

A moved process can retain its old pane ID.

Herdr keeps that old ID as a caller alias.

The current snapshot does not expose that alias.

Rai then compares the hook cwd with each pane foreground cwd.

Rai normalizes paths and resolves symbolic links before comparison.

A unique cwd match selects the process tree to check.

Duplicate cwd values require process evidence.

The script adds Claude's parent process ID as `parent_pid`.

Legacy beacons without `parent_pid` can use a unique cwd match alone.

Rai reads one local process table and builds the parent chain.

`herdr pane process-info` supplies each pane shell PID and foreground process list.

Rai matches the parent chain against those process IDs.

Remote process IDs cannot match the Mac process table.

A remote duplicate-cwd case stays uncorrelated without `HERDR_PANE_ID`.

## Transport and lifetime

Rai recreates `~/Library/Application Support/Rai/hooks.sock` at launch.

The socket mode is `0600`.

Rai refuses to replace a non-socket file at that path.

Rai also refuses to unlink a socket that has an active listener.

The receiver only removes the socket inode that it created.

The receiver accepts one newline-delimited JSON object per connection.

It limits each input line to 256 KiB.

The hook script drains and drops stdin above 240 KiB before it builds a shell value.

It limits retained `tool_input` data to 16 KiB.

It also limits retained hook messages and assistant text to 16 KiB each.

Rai keeps the newest timestamp for each correlated pane.

The script uses a subsecond timestamp to order asynchronous hook processes.

A notification permission beacon inherits the last tool data from its session.

A late tool beacon can also fill an earlier permission notification.

Non-actionable notifications cannot replace a pending summary while blocked.

Other lifecycle events also cannot replace that summary while the pane stays blocked.

Rai holds a blocked-state `Stop` separately for the later done notification.

Rai removes a pending beacon when a pane changes from `blocked` to another status.

Rai also removes beacons when their pane closes or the herd changes.

The `Stop` beacon remains available across status refresh races.

Rai uses its last assistant line until a newer hook arrives or the pane closes.

## Hook installation

Settings → Integrations shows the full proposed settings JSON before each change.

Rai uses `CLAUDE_CONFIG_DIR/settings.json` when that environment variable exists.

Otherwise, Rai uses `~/.claude/settings.json`.

Integrations lets the user select another Claude settings directory.

Rai rejects a symbolic-link settings file to preserve dotfile-managed links.

Install parses the selected settings file and keeps all existing hook handlers.

Repeated installation adds no duplicate handlers.

Each write keeps the prior file as `settings.json.bak`.

Remove deletes only Rai commands. It keeps the shared script because another settings file can use it.

Rai copies the script to Application Support.

The settings command uses that stable copy.

An application bundle path can change during replacement or an update.

The `PermissionRequest` handler runs in synchronous mode.

Its timeout equals the selected hold time plus 15 seconds.

The hold time defaults to 45 seconds and accepts values from 5 through 60 seconds.

The script read timeout equals the hold time plus 10 seconds.

This order gives Rai five seconds to start and Claude five seconds to finish.

All other handlers use Claude Code asynchronous hook mode.

The script writes through `nc -U` with a one-second timeout.

It uses Python socket code when `nc` fails or is absent.

The script always exits zero.

Non-decision events write no hook output.

The permission handler waits for one JSON response line.

Rai accepts that request line within two seconds and limits it to 256 KiB.

Rai records a diagnostic when a sender exceeds this limit.

`none`, socket errors, and timeouts write no output.

Claude then uses its normal local permission dialog.

## Notification and bridge use

Permission requests show the tool and one important input value.

Examples include a safe Bash command prefix, a file path, or a URL origin.

Notification bodies redact common credentials, request bodies, and all URL query values.

Known build commands show an allowlisted command prefix.

Other Bash requests show only the executable name, without arguments.

`AskUserQuestion` shows the first question.

`Stop` shows the final nonempty assistant line when it passes strict secret filters.

Mac notifications and APNs pushes use the same body builder.

Held permission pushes include Approve and Deny actions.

They include the request ID and an actionable tool question.

A conservative filter protects decision text before it reaches the lock screen.

Credential labels and authorization headers use generic text.

Standalone six-digit and opaque values become `•••`. Surrounding punctuation stays in place.

Four-digit values require a nearby credential label. Years, versions, and numeric path segments remain visible.

Slash tokens stay visible only when they match a plain absolute or relative path shape.

URL query values never reach the lock screen.

Direct file commands show their command and path.

Other shell commands keep the existing safe summary.

Held pushes bypass the presence delay and never coalesce.

Other structured beacon pushes remain tap-only.

Fallback pushes also stay tap-only while Rai-managed hooks are installed.

Late beacons replace the stable Mac notification and update a pending APNs event.

A beacon that arrives after delivery enters the same presence and burst gate again.

Per-device queues keep APNs order without making another device wait.

Fallback bodies remain `Needs you` and `Finished`.

Blocked sidebar rows show the same pending summary.

Bridge snapshot panes now have an optional `beacon` field.

A waiting beacon adds `request_id`, `awaits_decision`, and `deadline`.

The phone sends `decide` with the pane, request ID, and decision.

The Mac returns `decisionResult` after it accepts or rejects that request.

The Mac audits this write like other phone writes.

An expired or unknown request returns `That prompt already closed`.

Rai retracts the request-specific action push when the request closes.

Rai holds one request per pane because one pane exposes one current beacon.

Concurrent requests across panes keep separate notification identities.

This additive field does not change the merged bridge protocol version 6.

Old phone decoders ignore unknown object fields.

Phones announce decision support during bridge authentication.

The phone also sends `decisionAvailability` when notification or foreground state changes.

Notification permission enables background decisions. A foreground bridge connection also enables decisions.

The phone reads the current system permission after every foreground transition.

Rai never holds for an old phone without this capability.

The phone shows Approve, Deny, and the remaining hold time.

## Permission decisions

Rai adds a UUID request ID to each `PermissionRequest` beacon.

The hook keeps its socket open while the Mac holds the request.

The beacon carries the installed hold time to set the same deadline.

Rai holds only when the phone is reachable and the user is away.

Rai checks these conditions each second while it holds a request.

Rai ends the hold when the user returns.

Rai allows five seconds for a capable phone to reconnect before it ends the hold.

The feature toggle is on by default in Settings → Integrations.

Notification mute disables holds and decision pushes.

The Mac bridge must run before Rai holds a request.

Rai answers `none` when it cannot correlate the pane.

It also answers `none` when the hold expires or the herd changes.

An allowed response uses this Claude hook output:

```json
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}
```

A denied response includes a message:

```json
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from Rai Remote"}}}
```

These shapes match the Claude hooks reference and the interactive check.

Always-allow and auto-mode choices stay on the Mac.

The phone maps only exact `Yes` and `No` labels to hook decisions.

It hides all other choices and shows `answer on the Mac`.

The countdown uses elapsed phone time from beacon receipt. It does not compare Mac and phone wall clocks.

Older Macs and beacons without request IDs keep the key-based phone path.
