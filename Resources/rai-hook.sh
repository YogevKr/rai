#!/bin/sh

# Claude Code hook transport for Rai. Failures always leave Claude in control.

event=${1-}
case "$event" in
    ''|*[!A-Za-z0-9]*) exit 0 ;;
esac

# Keep the shell variable below 240 KiB and drain excess input safely.
payload=$( { head -c 245761; cat >/dev/null; } 2>/dev/null) || exit 0
payload_bytes=$(printf '%s' "$payload" | wc -c | tr -d ' ')
case "$payload_bytes" in
    ''|*[!0-9]*) exit 0 ;;
esac
[ "$payload_bytes" -le 245760 ] || exit 0
case "$payload" in
    \{*) ;;
    *) exit 0 ;;
esac

if command -v python3 >/dev/null 2>&1; then
    timestamp=$(python3 -c 'import time; print(f"{time.time_ns() / 1000000000:.9f}")' \
        2>/dev/null) || timestamp=0
else
    seconds=$(date +%s 2>/dev/null) || seconds=0
    timestamp="$seconds.$(printf '%06d' "$$")"
fi
parent_pid=${PPID:-0}
case "$parent_pid" in
    ''|*[!0-9]*) parent_pid=0 ;;
esac

prefix="{\"event\":\"$event\",\"ts\":$timestamp,\"parent_pid\":$parent_pid"
pane_id=${HERDR_PANE_ID-}
case "$pane_id" in
    '') ;;
    *[!A-Za-z0-9:._-]*) ;;
    *) prefix="$prefix,\"pane_id\":\"$pane_id\"" ;;
esac
herdr_socket_path=${HERDR_SOCKET_PATH-}
case "$herdr_socket_path" in
    '') ;;
    *[!A-Za-z0-9_./:-]*) ;;
    *) prefix="$prefix,\"herdr_socket_path\":\"$herdr_socket_path\"" ;;
esac

hold_seconds=${2-45}
case "$hold_seconds" in
    ''|*[!0-9]*) hold_seconds=45 ;;
esac
if [ "$hold_seconds" -lt 5 ] || [ "$hold_seconds" -gt 60 ]; then
    hold_seconds=45
fi

if [ "$event" = "PermissionRequest" ] && command -v python3 >/dev/null 2>&1; then
    if command -v uuidgen >/dev/null 2>&1; then
        request_id=$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]')
    elif command -v python3 >/dev/null 2>&1; then
        request_id=$(python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null)
    else
        request_id=
    fi
    case "$request_id" in
        ????????-????-????-????-????????????)
            prefix="$prefix,\"awaits_decision\":true,\"request_id\":\"$request_id\",\"decision_hold_seconds\":$hold_seconds"
            ;;
        *) request_id= ;;
    esac
fi

line="$prefix,${payload#\{}"

socket_path=${RAI_HOOK_SOCKET_PATH-}
if [ -z "$socket_path" ]; then
    socket_path="$HOME/Library/Application Support/Rai/hooks.sock"
fi

if [ "$event" = "PermissionRequest" ] && [ -n "$request_id" ] \
    && command -v python3 >/dev/null 2>&1; then
    # stdout is reserved for Claude's one structured decision object.
    printf '%s\n' "$line" | python3 -c '
import json
import socket
import sys

try:
    payload = sys.stdin.buffer.read()
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(1.0)
    client.connect(sys.argv[1])
    client.sendall(payload)
    client.settimeout(float(sys.argv[2]) + 10.0)
    response = client.makefile("rb").readline(65537)
    client.close()
    if len(response) > 65536:
        raise ValueError("decision response is too large")
    reply = json.loads(response)
    decision = reply.get("decision")
    if decision == "allow":
        output = {
            "hookSpecificOutput": {
                "hookEventName": "PermissionRequest",
                "decision": {"behavior": "allow"},
            }
        }
    elif decision == "deny":
        message = reply.get("message")
        if not isinstance(message, str) or not message.strip():
            message = "Denied from Rai Remote"
        output = {
            "hookSpecificOutput": {
                "hookEventName": "PermissionRequest",
                "decision": {"behavior": "deny", "message": message},
            }
        }
    else:
        raise ValueError("no hook decision")
    print(json.dumps(output, separators=(",", ":")))
except Exception:
    pass
' "$socket_path" "$hold_seconds" 2>/dev/null
    exit 0
fi

# Other events remain fire-and-forget. A Python-free permission hook also
# sends its beacon, then falls back to Claude's local dialog.
if command -v nc >/dev/null 2>&1; then
    if printf '%s\n' "$line" | nc -U -w 1 "$socket_path" >/dev/null 2>&1; then
        exit 0
    fi
fi

if command -v python3 >/dev/null 2>&1; then
    printf '%s\n' "$line" | python3 -c '
import socket
import sys

try:
    payload = sys.stdin.buffer.read()
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(1.0)
    client.connect(sys.argv[1])
    client.sendall(payload)
    client.close()
except Exception:
    pass
' "$socket_path" >/dev/null 2>&1
fi

exit 0
