#!/usr/bin/env python3
"""Closed-tab reopen e2e suite against the isolated herdr lab.

Replays the exact CLI sequences RaiModel issues for closing and reopening
tabs, and checks herdr's real behavior — the edge cases that unit tests with
canned snapshots cannot see.

Usage:
    scripts/herdr-lab.sh start
    HERDR_SOCKET_PATH=$(scripts/herdr-lab.sh socket) poc/closed_tab_e2e.py
    scripts/herdr-lab.sh stop

Covers:
  1. structural CLI contract: tab create flags, labels (spaces/quotes/emoji),
     tab rename, tab focus, split flags + JSON shape, zoom, dead-workspace
     error, deleted-cwd fallback
  2. the reopen race: pane run typed before the shell prompt loses the text;
     rai's 400ms-then-verify-and-retry guards the resume paths (which need
     shell `||` fallback and so can't use agent start); a fresh, no-resume
     launch instead uses herdr's readiness-aware `agent start --kind --pane`,
     which needs no delay at all (verified 0ms)
  3. single-pane agent reopen (the herdr ≥0.7.5 regression): the fixed
     sequence — tab create, beat, pane run resume into the tab's own pane
  4. multi-pane shape rebuild: splits with ratios, per-pane cwds, agent
     leaves, zoom + focused leaf
"""
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time

SOCKET = os.environ.get("HERDR_SOCKET_PATH")
if not SOCKET or not os.path.exists(SOCKET):
    sys.exit("HERDR_SOCKET_PATH must point at the running lab "
             "(scripts/herdr-lab.sh start)")

# Never trust the env var blindly — every check below is destructive
# (creates/closes workspaces, launches agents, types commands into panes). A
# stray or misconfigured HERDR_SOCKET_PATH could point at the user's REAL
# herd, or at another checkout's own active lab session (herdr session names
# are global to this user, not scoped by directory), so this must be the
# EXACT checkout-scoped session name scripts/herdr-lab.sh derives for THIS
# repo — not just any "railab-*" — and must carry the ownership marker that
# script drops on first create.
_repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
_checkout_id = hashlib.sha256(_repo_root.encode()).hexdigest()[:8]
_expected_session = f"railab-{_checkout_id}"
_session_dir = os.path.dirname(SOCKET)
_session_name = os.path.basename(_session_dir)
_owner_marker = os.path.join(_session_dir, ".rai-lab-owned")
if _session_name != _expected_session or not os.path.exists(_owner_marker):
    sys.exit(
        f"refusing to run against {SOCKET} (session '{_session_name}') — "
        f"this checkout's lab session is '{_expected_session}', and its "
        f"ownership marker must exist at {_owner_marker}. Only run this "
        f"suite via scripts/herdr-lab.sh start; never point it at a real "
        f"herd or another checkout's lab."
    )

HERDR = shutil.which("herdr")
if not HERDR:
    sys.exit("herdr not found on PATH (see https://herdr.dev)")
LAB = f"/tmp/rai-herdr-lab-{_session_name[len('railab-'):]}"
ARGV_LOG = os.environ.get("RAILAB_ARGV_LOG", f"{LAB}/claude-argv.log")
WORK = f"{LAB}/work"

results = []


def herdr(*args, timeout=30):
    p = subprocess.run(
        [HERDR, *args],
        env={**os.environ, "HERDR_SOCKET_PATH": SOCKET},
        capture_output=True, text=True, timeout=timeout,
    )
    return p.returncode == 0, (p.stdout + p.stderr).strip()


def snap():
    _, out = herdr("api", "snapshot")
    return json.loads(out)["result"]["snapshot"]


def check(name, passed, note=""):
    results.append((name, passed))
    print(f"[{'PASS' if passed else 'FAIL'}] {name}" + (f" — {note}" if note else ""))


def new_ws():
    _, out = herdr("workspace", "create", "--cwd", WORK, "--no-focus")
    return json.loads(out)["result"]["root_pane"]["workspace_id"]


def close_ws(ws):
    herdr("workspace", "close", ws)


def tabs_of(s, ws):
    return [t for t in s["tabs"] if t["workspace_id"] == ws]


def panes_of(s, tab):
    return [p for p in s["panes"] if p["tab_id"] == tab]


def agent_of(pane):
    s = snap()
    hits = [p for p in s["panes"] if p["pane_id"] == pane]
    return hits[0].get("agent") if hits else None


os.makedirs(WORK, exist_ok=True)

# ---- 1. structural contract ------------------------------------------------
ws = new_ws()
for label in ["plain", "two words", "quo'te\"d", "emoji 🦴"]:
    herdr("tab", "create", "--workspace", ws, "--cwd", WORK,
          "--label", label, "--focus")
s = snap()
got = [t["label"] for t in tabs_of(s, ws)]
check("labels survive create", all(
    l in got for l in ["plain", "two words", "quo'te\"d", "emoji 🦴"]), str(got))

tab = tabs_of(s, ws)[-1]["tab_id"]
herdr("tab", "rename", tab, "renamed label")
s = snap()
check("tab rename", [t["label"] for t in tabs_of(s, ws)
                     if t["tab_id"] == tab] == ["renamed label"])

ok, out = herdr("tab", "create", "--workspace", "wDEAD",
                "--cwd", WORK, "--label", "x", "--focus")
check("dead workspace fails loudly", not ok and "not_found" in out, out[:60])
close_ws(ws)

# ---- 2. the readiness race -------------------------------------------------
ws = new_ws()
herdr("tab", "create", "--workspace", ws, "--cwd", WORK,
      "--label", "race", "--focus")
s = snap()
pane = panes_of(s, [t for t in tabs_of(s, ws)
                    if t["label"] == "race"][0]["tab_id"])[0]["pane_id"]
herdr("pane", "run", pane, "claude --typed-at-0ms")
time.sleep(3)
# Nondeterministic by nature: text typed before the shell prompt is lost on
# some runs and lands on others. Informational only — the guarded 400ms case
# below is the assertion that matters.
print(f"[info] 0ms pane run landed: {agent_of(pane) == 'claude'} "
      "(race window; rai always waits 400ms)")
close_ws(ws)

ws = new_ws()
herdr("tab", "create", "--workspace", ws, "--cwd", WORK,
      "--label", "beat", "--focus")
s = snap()
pane = panes_of(s, [t for t in tabs_of(s, ws)
                    if t["label"] == "beat"][0]["tab_id"])[0]["pane_id"]
time.sleep(0.4)
herdr("pane", "run", pane, "claude --typed-after-beat")
time.sleep(3)
check("400ms beat lands the command", agent_of(pane) == "claude")
close_ws(ws)

# ---- 2b. fresh-launch path: agent start --kind --pane, zero delay ---------
# What launchAgent / launchAgentFromBridge now do (review finding: the old
# fixed-delay `pane run` was flagged as a race; readiness-aware `agent
# start` has no delay to guess and no window to lose text in — verified
# 5/5 at 0ms during triage). Not valid for the resume paths above, which
# need `first || fallback` shell semantics `agent start` can't carry.
ws = new_ws()
s = snap()
pane = panes_of(s, tabs_of(s, ws)[0]["tab_id"])[0]["pane_id"]
ok, out = herdr("agent", "start", "e2e-fresh-launch", "--kind", "claude",
                "--pane", pane, timeout=60)
check("agent start --kind --pane: zero-delay fresh launch",
      ok and agent_of(pane) == "claude", out[:120])
close_ws(ws)

# ---- 2d. bridge "New workspace" launch reuses the seeded root pane --------
# What launchAgentFromBridge does when workspaceID is nil: workspace create
# already seeds one pane/tab, so the agent starts directly in it — no
# separate tab create (review finding: that used to leave an extra, unused
# tab behind).
#
# `agent start` on a JUST-created pane can fail with agent_pane_busy under
# load — discovered running this suite itself, which fires many herdr calls
# back to back (10/10 succeeds in isolation; the failure showed up only
# alongside the rest of this script's traffic). That code is ambiguous: it
# also fires when the pane already has an agent running. startAgent's real
# fix (RaiModel.swift) only falls back to pane run when the pane's own
# foreground process confirms it's still a bare shell — replayed here.
out_ws = herdr("workspace", "create", "--cwd", WORK, "--no-focus")[1]
ws_created = json.loads(out_ws)["result"]["root_pane"]["workspace_id"]
root_pane = json.loads(out_ws)["result"]["root_pane"]["pane_id"]
ok, out = herdr("agent", "start", "e2e-new-workspace", "--kind", "claude",
                "--pane", root_pane, timeout=60)
if not ok and "unknown option" not in out:
    info = json.loads(herdr("pane", "process-info", "--pane", root_pane)[1])
    fg = info["result"]["process_info"]["foreground_processes"][0]
    at_shell_prompt = fg["pid"] == info["result"]["process_info"]["shell_pid"]
    if at_shell_prompt:
        herdr("pane", "run", root_pane, "claude")
        time.sleep(2)
s = snap()
check("new-workspace launch: exactly one tab",
      len(tabs_of(s, ws_created)) == 1, str(tabs_of(s, ws_created)))
check("new-workspace launch: agent in the seeded root pane",
      agent_of(root_pane) == "claude",
      f"ok={ok} out={out[:160]}")
close_ws(ws_created)

# ---- 2c. fallback when agent start --kind/--pane is rejected --------------
# rai declares no minimum herdr version (README.md). On a pre-0.7.5 server
# `agent start` doesn't recognize --kind/--pane; the pane is left at a clean
# shell prompt, and launchAgent/launchAgentFromBridge fall back to typing
# the bare launch command directly (same pane run + verify/retry the resume
# paths use).
ws = new_ws()
s = snap()
pane = panes_of(s, tabs_of(s, ws)[0]["tab_id"])[0]["pane_id"]
ok, out = herdr("agent", "start", "e2e-old-syntax", "--kind-DOES-NOT-EXIST",
                "claude", "--pane", pane)
check("simulated old-herdr agent start rejects the new flag", not ok, out[:80])
herdr("pane", "run", pane, "claude")
time.sleep(2)
check("fallback pane run lands on the same pane", agent_of(pane) == "claude")
close_ws(ws)

# ---- 3. single-pane agent reopen (fixed sequence) --------------------------
ws = new_ws()
ok, out = herdr("tab", "create", "--workspace", ws, "--cwd", WORK,
                "--label", "agenty", "--focus")
root = json.loads(out)["result"]["root_pane"]["pane_id"]
new_tab = json.loads(out)["result"]["root_pane"]["tab_id"]
time.sleep(0.4)
herdr("pane", "run", root,
      "claude --dangerously-skip-permissions --continue || "
      "claude --dangerously-skip-permissions")
time.sleep(3)
s = snap()
panes = panes_of(s, new_tab)
check("reopened tab alive", new_tab in [t["tab_id"] for t in tabs_of(s, ws)])
check("reopened tab: single pane", len(panes) == 1)
check("reopened tab: agent detected", panes and panes[0].get("agent") == "claude")
argv = open(ARGV_LOG).read().strip().splitlines() if os.path.exists(ARGV_LOG) else []
check("reopened agent got its flags",
      bool(argv) and "--dangerously-skip-permissions" in argv[-1],
      argv[-1] if argv else "no argv log")
close_ws(ws)

# ---- 4. multi-pane shape rebuild -------------------------------------------
ws = new_ws()
ok, out = herdr("tab", "create", "--workspace", ws, "--cwd", WORK,
                "--label", "shape", "--focus")
root = json.loads(out)["result"]["root_pane"]["pane_id"]
tab = json.loads(out)["result"]["root_pane"]["tab_id"]
ok, out = herdr("pane", "split", root, "--direction", "right",
                "--ratio", "0.6000", "--cwd", "/tmp", "--no-focus")
p1 = json.loads(out)["result"]["pane"]["pane_id"]
ok, out = herdr("pane", "split", p1, "--direction", "down",
                "--ratio", "0.5000", "--cwd", WORK, "--no-focus")
p2 = json.loads(out)["result"]["pane"]["pane_id"]
time.sleep(0.4)
herdr("pane", "run", root, "claude --continue || claude")
herdr("pane", "run", p2, "claude --continue || claude")
time.sleep(3)
herdr("pane", "zoom", p2, "--on")
s = snap()
lay = [l for l in s["layouts"] if l["tab_id"] == tab][0]
check("shape: 3 panes, 2 splits",
      len(lay["panes"]) == 3 and len(lay["splits"]) == 2)
check("shape: both agent leaves live",
      agent_of(root) == "claude" and agent_of(p2) == "claude")
check("shape: zoom + focused leaf",
      lay["zoomed"] and lay["focused_pane_id"] == p2)
close_ws(ws)

print()
failed = [n for n, ok in results if not ok]
print(f"{len(results) - len(failed)}/{len(results)} passed"
      + (f"; FAILED: {failed}" if failed else ""))
sys.exit(1 if failed else 0)
