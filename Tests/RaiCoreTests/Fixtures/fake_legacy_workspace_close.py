#!/usr/bin/env python3
"""Owned legacy closure fixture. Records sockets, writes, and reader cleanup."""
import copy
import json
import os
import socketserver
import sys
import threading

socket_path, mode, record_path = sys.argv[1:]
lock = threading.Lock()
sequence = 0
connection_ids = {}
workspace = {"workspace_id": "w1", "number": 1, "label": "Reviewed workspace", "focused": True,
             "pane_count": 1, "tab_count": 1, "active_tab_id": "w1:t1", "agent_status": "unknown"}
if mode in ("metadata", "group", "unknown_primary"):
    workspace["worktree"] = {"repo_key": None if mode == "unknown_primary" else "repo",
                             "repo_name": "repo", "repo_root": "/tmp/repo", "checkout_path": "/tmp/repo",
                             "is_linked_worktree": mode == "metadata"}
snapshot = {"version": "0.8.2", "protocol": 20, "workspaces": [workspace], "tabs": [], "panes": [], "layouts": []}
with open(record_path + ".preview", "w") as preview:
    json.dump(snapshot, preview)


def record(value):
    with lock, open(record_path, "a") as output:
        output.write(json.dumps(value) + "\n")


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        connection = connection_ids[id(self.request)]
        record({"connection": connection, "server": self.server.identity})
        try:
            line = self.rfile.readline()
            if not line:
                return
            request = json.loads(line)
            record({"request": request, "connection": connection, "server": self.server.identity})
            if request["method"] == "session.snapshot":
                if mode == "stall":
                    self.rfile.read()
                    return
                current = copy.deepcopy(snapshot)
                if mode == "metadata":
                    current["workspaces"][0]["worktree"]["checkout_path"] = "/tmp/replacement"
                if mode == "missing":
                    current["workspaces"][0]["workspace_id"] = "replacement"
                if mode == "group":
                    child = copy.deepcopy(workspace)
                    child["workspace_id"] = "w2"
                    child["worktree"]["is_linked_worktree"] = True
                    current["workspaces"].append(child)
                if mode in ("replace", "drop_reply"):
                    os.unlink(socket_path)
                    replacement = Server(socket_path, Handler)
                    replacement.identity = "replacement"
                    threading.Thread(target=replacement.serve_forever, daemon=True).start()
                result = {"type": "session_snapshot", "snapshot": current}
            else:
                if mode == "drop_reply":
                    return
                result = {"type": "workspace_closed"}
            self.wfile.write(json.dumps({"id": request["id"], "result": result}).encode() + b"\n")
            self.wfile.flush()
            self.rfile.read()
        finally:
            record({"closed": connection, "server": self.server.identity})


class Server(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True
    identity = "original"

    def get_request(self):
        global sequence
        connection, address = super().get_request()
        with lock:
            sequence += 1
            connection_ids[id(connection)] = sequence
        return connection, address


with Server(socket_path, Handler) as server:
    server.serve_forever()
