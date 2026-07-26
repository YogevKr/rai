#!/usr/bin/env python3
"""rai PoC — a minimal herdr socket client.

Proves the exact loop a native macOS GUI would build on, from a script first:
connect to the herdr unix socket, read the full workspace/tab/pane tree
(`session.snapshot`), stream live events (`events.subscribe`), and drive a pane
(`pane.read` / `pane.send_input`). Wire format: AF_UNIX SOCK_STREAM, one
newline-delimited JSON object per message, requests `{id, method, params}`,
responses `{id, result|error}`, events `{event, data}`.

Usage:
    herdr_client.py tree                 # render the live tree
    herdr_client.py watch [--secs N]     # stream events (default: until Ctrl-C)
    herdr_client.py read  <pane_id> [--lines N]
    herdr_client.py send  <pane_id> <text>   # e.g. 'echo hi\\n'
"""
from __future__ import annotations

import argparse
import itertools
import json
import os
import socket
import sys

SOCKET_PATH = os.path.expanduser(
    os.environ.get("HERDR_SOCKET_PATH", "~/.config/herdr/herdr.sock")
)


class Herdr:
    """One RPC connection. Skips any event lines that arrive while awaiting a
    response id (herdr multiplexes events onto every connection)."""

    def __init__(self, path: str = SOCKET_PATH):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(path)
        self.rfile = self.sock.makefile("r", encoding="utf-8")
        self._ids = itertools.count(1)

    def call(self, method: str, **params):
        rid = str(next(self._ids))
        self.sock.sendall(
            (json.dumps({"id": rid, "method": method, "params": params}) + "\n").encode()
        )
        for line in self.rfile:
            msg = json.loads(line)
            if msg.get("id") == rid:
                if "error" in msg:
                    raise RuntimeError(msg["error"])
                return msg.get("result")
        raise RuntimeError("connection closed before response")

    def stream(self, subscriptions: list[dict]):
        """Yield (event, data) tuples forever on a dedicated connection."""
        self.sock.sendall(
            (json.dumps({"id": "sub", "method": "events.subscribe",
                         "params": {"subscriptions": subscriptions}}) + "\n").encode()
        )
        for line in self.rfile:
            msg = json.loads(line)
            if msg.get("event"):
                yield msg["event"], msg.get("data", {})


GLYPH = {"working": "✳", "blocked": "‼", "done": "✔", "idle": "·", "unknown": "?"}


def cmd_tree(h: Herdr) -> None:
    snap = h.call("session.snapshot")["snapshot"]
    focus = snap.get("focused_pane_id")
    print(f"herdr {snap.get('version')} · protocol {snap.get('protocol')} · "
          f"{len(snap.get('workspaces', []))} spaces\n")
    for ws in snap.get("workspaces", []):
        wt = ws.get("worktree") or {}
        tag = f"  [{wt.get('repo_name')}]" if wt.get("is_linked_worktree") else ""
        print(f"{GLYPH.get(ws.get('agent_status'), ' ')} {ws['label']}"
              f"  ({ws.get('tab_count')} tabs){tag}"
              f"{'   ← focused' if ws.get('focused') else ''}")


def cmd_watch(h: Herdr, secs) -> None:
    subs = [{"type": t} for t in (
        "layout.updated", "pane.created", "pane.closed", "pane.moved",
        "pane.focused", "pane.exited", "tab.closed", "workspace.focused",
    )]
    print("streaming events (Ctrl-C to stop)…")
    if secs:
        h.sock.settimeout(secs)
    try:
        for event, data in h.stream(subs):
            summary = data.get("pane_id") or data.get("workspace_id") or data.get("tab_id") or ""
            print(f"  {event:<26} {summary}")
    except (KeyboardInterrupt, socket.timeout):
        pass


def cmd_read(h: Herdr, pane_id: str, lines: int) -> None:
    res = h.call("pane.read", pane_id=pane_id, source="recent", lines=lines, format="text")
    print(res.get("text") or json.dumps(res)[:2000])


def cmd_send(h: Herdr, pane_id: str, text: str) -> None:
    h.call("pane.send_input", pane_id=pane_id, text=text.encode().decode("unicode_escape"))
    print(f"sent {len(text)} chars to {pane_id}")


def main() -> int:
    p = argparse.ArgumentParser(description="rai PoC herdr socket client")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("tree")
    w = sub.add_parser("watch"); w.add_argument("--secs", type=float, default=None)
    r = sub.add_parser("read"); r.add_argument("pane_id"); r.add_argument("--lines", type=int, default=40)
    s = sub.add_parser("send"); s.add_argument("pane_id"); s.add_argument("text")
    args = p.parse_args()

    try:
        h = Herdr()
    except OSError as exc:
        print(f"rai: cannot reach herdr socket at {SOCKET_PATH}: {exc}", file=sys.stderr)
        return 1

    if args.cmd == "tree":
        cmd_tree(h)
    elif args.cmd == "watch":
        cmd_watch(h, args.secs)
    elif args.cmd == "read":
        cmd_read(h, args.pane_id, args.lines)
    elif args.cmd == "send":
        cmd_send(h, args.pane_id, args.text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
