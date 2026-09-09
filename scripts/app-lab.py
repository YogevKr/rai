#!/usr/bin/env python3
"""Prepare and launch an app lab without changing the installed Rai or Herdr."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import socket
import subprocess
import tempfile
import time
import uuid


def prepare(herdr=None):
    root = Path(tempfile.mkdtemp(prefix="rai09-", dir="/tmp")).resolve()
    lab_id = "e2e-" + uuid.uuid4().hex[:12]
    identifier = "gr.krig.rai.lab." + lab_id
    (root / ".rai-lab-owned").write_text(identifier)
    for name in ("bin", "config/herdr", "state", "cache", "support", "claude", "codex", "repos", "apps", "shell", "tmp"):
        (root / name).mkdir(parents=True, exist_ok=True)
    binary = root / "bin/herdr"
    if herdr is not None:
        shutil.copy2(Path(herdr).resolve(), binary)
        binary.chmod(0o700)
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    config = root / "config/herdr/config.toml"
    config.write_text("")
    environment = {key: os.environ[key] for key in ("HOME", "USER", "LOGNAME") if key in os.environ}
    environment.update(
        PATH=str(root / "bin") + ":/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        TERM="xterm-256color", SHELL="/bin/zsh", RAI_DATA_ROOT=str(root),
        HERDR_BIN_PATH=str(binary), HERDR_CONFIG_PATH=str(config),
        HERDR_SOCKET_PATH=str(root / "config/herdr/sessions/lab/herdr.sock"),
        XDG_CONFIG_HOME=str(root / "config"), XDG_STATE_HOME=str(root / "state"),
        XDG_CACHE_HOME=str(root / "cache"), CLAUDE_CONFIG_DIR=str(root / "claude"),
        CODEX_HOME=str(root / "codex"), TMPDIR=str(root / "tmp") + "/",
        RAI_BRIDGE_PORT=str(port), RAI_PAIRING_CODE_FILE=str(root / "pairing-code"),
        RAI_HOOK_SOCKET_PATH=str(root / "support/hooks.sock"),
        ZDOTDIR=str(root / "shell"), GIT_CONFIG_GLOBAL=str(root / "gitconfig"),
    )
    if herdr is None:
        environment["RAI_LAB_ALLOW_MISSING_HERDR"] = "1"
        environment["HERDR_SOCKET_PATH"] = str(root / "config/herdr/herdr.sock")
    manifest = {"bundle_id": identifier, "lab_id": lab_id, "root": str(root), "environment": environment}
    (root / "lab.json").write_text(json.dumps(manifest, indent=2))
    print(json.dumps({"root": str(root), "lab_id": lab_id, "bundle_id": identifier, "bridge_port": port}))


def load_lab(root):
    root = Path(root).resolve()
    manifest = json.loads((root / "lab.json").read_text())
    if manifest["root"] != str(root) or (root / ".rai-lab-owned").read_text() != manifest["bundle_id"]:
        raise ValueError("Lab ownership check failed")
    return root, manifest


def launch(root, app):
    root, manifest = load_lab(root)
    app = Path(app).resolve()
    if not app.is_relative_to(root / "apps"):
        raise ValueError("The test app must be inside this lab's apps directory")
    with (app / "Contents/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    if info["CFBundleIdentifier"] != manifest["bundle_id"]:
        raise ValueError("App bundle identity does not match this lab")
    env = manifest["environment"]
    if any(root.glob("herdr-*.json")):
        raise ValueError("Herdr already has a recorded process; inspect it before launching again")
    for name in ("herdr", "app"):
        if (root / (name + ".pid")).exists():
            raise ValueError(f"{name} already has a recorded process; inspect it before launching again")
    executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
    # Use the app's validator before any Herdr process can touch persistent state.
    subprocess.run([str(executable), "--validate-lab"], env=env, cwd=root, check=True)
    commands = [("app", [str(executable), "-companionBridgeEnabled", "YES"])]
    # Missing-install tests let Rai discover and start its default server after Retry.
    if env.get("RAI_LAB_ALLOW_MISSING_HERDR") != "1":
        commands.insert(0, ("herdr", [env["HERDR_BIN_PATH"], "--session", "lab", "server"]))
    for name, command in commands:
        pid_file = root / (name + ".pid")
        with (root / (name + ".log")).open("ab") as output:
            process = subprocess.Popen(command, cwd=root / "repos", env=env,
                                       stdin=subprocess.DEVNULL, stdout=output, stderr=output,
                                       start_new_session=True)
        pid_file.write_text(str(process.pid))
        if name == "herdr":
            wait_for_socket(process, env["HERDR_SOCKET_PATH"], name)
        else:
            wait_for_socket(process, env["RAI_HOOK_SOCKET_PATH"], name)
            # Deliver the normal reopen event after AppKit registers the process.
            # Direct executable launches can otherwise restore no window.
            subprocess.run(["/usr/bin/open", "-a", str(app)], check=True)
            wait_for_bridge(process, env["RAI_BRIDGE_PORT"])
    print(json.dumps({"root": str(root), "app": str(app), "socket": env["HERDR_SOCKET_PATH"]}))


def wait_for_socket(process, socket_path, name):
    for _ in range(100):
        if process.poll() is not None:
            raise RuntimeError(f"Test {name} exited; inspect {name}.log")
        if Path(socket_path).exists() and process_owns_socket(process, ["-U"], socket_path):
            return
        time.sleep(0.1)
    raise RuntimeError(f"Test {name} socket did not appear; inspect {name}.log")


def wait_for_bridge(process, port):
    for _ in range(100):
        if process.poll() is not None:
            raise RuntimeError("Test app exited before its bridge started; inspect app.log")
        if process_owns_socket(process, ["-iTCP:" + str(port), "-sTCP:LISTEN"]):
            return
        time.sleep(0.1)
    raise RuntimeError("Test app does not own its bridge port; inspect app.log")


def process_owns_socket(process, options, name=None):
    listener = subprocess.run(
        ["/usr/sbin/lsof", "-nP", "-a", "-p", str(process.pid), *options, "-F", "pn"],
        capture_output=True, text=True, check=False,
    )
    fields = listener.stdout.splitlines()
    if listener.returncode != 0 or f"p{process.pid}" not in fields:
        return False
    return name is None or any(
        field.startswith("n/") and Path(field[1:]).resolve() == Path(name).resolve()
        for field in fields
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    create = commands.add_parser("prepare")
    source = create.add_mutually_exclusive_group(required=True)
    source.add_argument("--herdr")
    source.add_argument("--without-herdr", action="store_true")
    start = commands.add_parser("launch")
    start.add_argument("--root", required=True)
    start.add_argument("--app", required=True)
    args = parser.parse_args()
    if args.command == "prepare":
        prepare(args.herdr)
    else:
        launch(args.root, args.app)
