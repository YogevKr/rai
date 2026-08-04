#!/bin/bash
# Isolated herdr lab for rai end-to-end tests.
#
# Runs a named herdr session ("railab") with its own state and sockets, plus
# a fake `claude` on PATH so agent panes are cheap and deterministic. The
# user's default herd and its persisted session.json are never touched.
#
#   scripts/herdr-lab.sh start    # create session + shim, print socket path
#   scripts/herdr-lab.sh status   # is the lab running, where is the socket
#   scripts/herdr-lab.sh stop     # stop and delete the lab session
#   scripts/herdr-lab.sh socket   # print the lab's HERDR_SOCKET_PATH
#
# Gotchas encoded here (learned the hard way):
# - unix sockets cap sun_path at ~104 bytes: the lab root must stay short.
# - herdr resolves its config dir from the passwd home, not $HOME — real
#   isolation comes from a NAMED session, not an env override.
# - a TUI inside a herdr pane refuses to nest: the lab launches through
#   `env -i` with the herdr environment stripped.
# - a headless named session needs a SIZED pty (`script` + stty), or every
#   workspace create fails with rows=0 cols=0.
# - the fake claude must KEEP its process name (no `exec sleep`): herdr's
#   agent detection matches the foreground process name.
# - the session name is just a label; a real user session (or a lab from a
#   different checkout) could already own it. An ownership marker dropped
#   inside the session's OWN directory on first create is what start/stop
#   actually check — never assume the name is ours just because it matches.
# - herdr session names are global to this user, not scoped by checkout —
#   two worktrees running this script would otherwise fight over the same
#   name and stop each other's active test. The checkout path is hashed into
#   the session name (and the shim dir) so concurrent checkouts get distinct
#   labs automatically; the hash is short (8 hex chars) to stay well under
#   the ~104-byte sun_path cap once appended to a socket path.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKOUT_ID="$(printf '%s' "$REPO_ROOT" | shasum -a 256 | cut -c1-8)"
SESSION="railab-$CHECKOUT_ID"
LAB="/tmp/rai-herdr-lab-$CHECKOUT_ID"
HERDR="$(command -v herdr || true)"
SESSION_DIR="$HOME/.config/herdr/sessions/$SESSION"
OWNER_MARKER="$SESSION_DIR/.rai-lab-owned"
SOCKET="$SESSION_DIR/herdr.sock"

if [ -z "$HERDR" ]; then
    echo "herdr not found on PATH (see https://herdr.dev)" >&2
    exit 1
fi

install_shim() {
    mkdir -p "$LAB/bin" "$LAB/work"
    cat > "$LAB/bin/claude" <<'SHIM'
#!/bin/sh
# rai lab fake agent: records argv, keeps a claude-named process alive.
echo "$@" >> "${RAILAB_ARGV_LOG:-/tmp/rai-herdr-lab/claude-argv.log}"
echo "fake-claude ready pid=$$ args: $*"
while :; do sleep 3600; done
SHIM
    chmod +x "$LAB/bin/claude"
}

running() {
    "$HERDR" session list --json 2>/dev/null \
        | python3 -c "
import json, sys
sessions = json.load(sys.stdin)['sessions']
print(any(s['name'] == '$SESSION' and s['running'] for s in sessions))
" 2>/dev/null | grep -q True
}

require_ownership() {
    if [ -e "$SESSION_DIR" ] && [ ! -e "$OWNER_MARKER" ]; then
        echo "refusing to touch '$SESSION' — it exists but wasn't created by" \
             "this lab (no $OWNER_MARKER). If it's stale, remove it by hand" \
             "with 'herdr session delete $SESSION' after checking it's not in" \
             "use; otherwise rename SESSION in this script." >&2
        exit 1
    fi
}

case "${1:-status}" in
start)
    install_shim
    require_ownership
    if running; then
        echo "lab already running: $SOCKET"
        exit 0
    fi
    # Claim ownership BEFORE launching, not after success: require_ownership
    # just vetted this directory (absent, or already ours), so anything this
    # attempt creates — even a failed one herdr half-initializes — is ours to
    # clean up on a later stop.
    mkdir -p "$SESSION_DIR"
    touch "$OWNER_MARKER"
    # $HERDR is an absolute path resolved above, so the exec below reaches
    # herdr regardless of this inner PATH — it only needs to cover whatever
    # herdr itself shells out to (git, ssh, ...) plus the fake claude shim.
    (cd "$LAB" && nohup env -i \
        HOME="$HOME" TERM=xterm-256color SHELL=/bin/sh \
        USER="$(id -un)" LOGNAME="$(id -un)" \
        PATH="$LAB/bin:$(dirname "$HERDR"):/usr/local/bin:/usr/bin:/bin" \
        RAILAB_ARGV_LOG="$LAB/claude-argv.log" \
        script -q /dev/null sh -c \
        "stty rows 40 cols 120; exec $HERDR --session $SESSION" \
        > "$LAB/tui.log" 2>&1 &)
    for _ in $(seq 1 20); do
        running && break
        sleep 0.5
    done
    running || { echo "lab failed to start; see $LAB/tui.log" >&2; exit 1; }
    echo "$SOCKET"
    ;;
stop)
    if [ ! -e "$SESSION_DIR" ]; then
        echo "lab not running"
        exit 0
    fi
    require_ownership
    if running; then
        if ! HERDR_SOCKET_PATH="$SOCKET" "$HERDR" server stop >/dev/null 2>&1; then
            echo "failed to stop '$SESSION' — it is likely still running" >&2
            exit 1
        fi
        sleep 1
    fi
    if ! "$HERDR" session delete "$SESSION" >/dev/null 2>&1; then
        echo "failed to delete session '$SESSION' — it may still exist" >&2
        exit 1
    fi
    echo "lab stopped"
    ;;
status)
    if running; then
        echo "running: $SOCKET"
    else
        echo "not running"
        exit 1
    fi
    ;;
socket)
    echo "$SOCKET"
    ;;
*)
    echo "usage: $0 {start|stop|status|socket}" >&2
    exit 2
    ;;
esac
