#!/bin/sh

# Claude Code hook transport for Rai. It never writes a hook decision.
# All failures are silent because telemetry must not change Claude's behavior.

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
line="$prefix,${payload#\{}"

socket_path=${RAI_HOOK_SOCKET_PATH-}
if [ -z "$socket_path" ]; then
    socket_path="$HOME/Library/Application Support/Rai/hooks.sock"
fi

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
