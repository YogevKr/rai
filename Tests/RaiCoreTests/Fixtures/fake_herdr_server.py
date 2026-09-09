#!/usr/bin/env python3
"""Disposable one-request-per-connection server for transport regression tests."""
import json
import socketserver
import sys
import threading

socket_path, mode, record_path = sys.argv[1:]
record_lock = threading.Lock()
state_lock = threading.Lock()
subscription = None
panes = []
rename_protocol = int(mode.removeprefix("events_rename_")) if mode.startswith("events_rename_") else None
workspace_label = "initial"
closed_protocol = int(mode.removeprefix("events_closed_")) if mode.startswith("events_closed_") else None
workspace_closed = False


def pane(number):
    return {"pane_id": f"w1:p{number}", "terminal_id": f"terminal-{number}",
            "workspace_id": "w1", "tab_id": "w1:t1", "focused": number == 1,
            "agent_status": "unknown", "cwd": "/tmp", "revision": 0}


panes.append(pane(1))


class Handler(socketserver.StreamRequestHandler):
    def reply(self, value):
        self.wfile.write(json.dumps(value).encode() + b"\n")
        self.wfile.flush()

    def events(self, request):
        global subscription, workspace_label, workspace_closed
        types = {item["type"] for item in request["params"]["subscriptions"]}
        if rename_protocol is not None:
            unsupported = ((rename_protocol < 14 and "workspace.renamed" in types)
                           or (rename_protocol < 19 and "workspace.reordered" in types))
            if unsupported:
                self.reply({"id": request["id"], "error": {"code": "invalid_request", "message": "Unknown event type"}})
                return
        if closed_protocol is not None and closed_protocol < 1 and "workspace.closed" in types:
            self.reply({"id": request["id"], "error": {"code": "invalid_request", "message": "Unknown event type"}})
            return
        if mode == "events_bad_ack":
            self.reply({"id": "sub", "result": {"type": "ok"}})
            return
        if mode == "events_before_ack":
            self.reply({"event": "pane_created", "data": {"pane_id": "w1:p2"}})
            return
        if mode == "events_no_ack":
            self.rfile.read()
            return
        state = {"snapshot_started": threading.Event(), "event_sent": threading.Event()}
        with state_lock:
            subscription = state
        self.reply({"id": "sub", "result": {"type": "subscription_started"}})
        if not state["snapshot_started"].wait(5):
            return
        if closed_protocol is not None:
            if "workspace.closed" in types:
                with state_lock:
                    workspace_closed = True
                    panes.clear()
                self.reply({"event": "workspace_closed", "data": {"workspace_id": "w1"}})
            state["event_sent"].set()
            self.rfile.read()
            return
        if rename_protocol is not None:
            if "workspace.renamed" in types:
                with state_lock:
                    workspace_label = "renamed"
                self.reply({"event": "workspace_renamed", "data": {"workspace_id": "w1", "label": workspace_label}})
            state["event_sent"].set()
            self.rfile.read()
            return
        with state_lock:
            created = pane(len(panes) + 1)
            panes.append(created)
        self.reply({"event": "pane_created", "data": created})
        state["event_sent"].set()
        self.rfile.read()

    def snapshot(self, request):
        with state_lock:
            captured = list(panes)
            state = subscription
            label = workspace_label
            closed = workspace_closed
        if state is not None:
            state["snapshot_started"].set()
            if not state["event_sent"].wait(5):
                return
        workspaces = [] if (rename_protocol is None and closed_protocol is None) or closed else [{
            "workspace_id": "w1", "number": 1, "label": label, "focused": True,
            "pane_count": 1, "tab_count": 1, "active_tab_id": "w1:t1", "agent_status": "unknown"}]
        self.reply({"id": request["id"], "result": {"type": "session_snapshot", "snapshot": {
            "version": "0.8.2" if mode == "events_legacy" else "0.9.0",
            "protocol": closed_protocol if closed_protocol is not None else (rename_protocol if rename_protocol is not None else (20 if mode == "events_legacy" else 22)),
            "workspaces": workspaces, "tabs": [], "layouts": [], "panes": captured}}})

    def handle(self):
        request = json.loads(self.rfile.readline())
        with record_lock, open(record_path, "a") as record:
            record.write(json.dumps(request) + "\n")
        if request["method"] == "events.subscribe":
            self.events(request)
            return
        if request["method"] == "session.snapshot":
            self.snapshot(request)
            return
        if request["method"] == "pane.graphics.info":
            if mode == "graphics_stall":
                self.rfile.read()
                with record_lock, open(record_path + ".graphics-closed", "a") as record:
                    record.write("closed\n")
                return
            graphics_errors = {
                "graphics_disabled": "feature_disabled",
                "graphics_cell_size": "cell_size_unavailable",
                "graphics_unknown": "unknown_method",
            }
            if mode in graphics_errors:
                self.reply({"id": request["id"], "error": {
                    "code": graphics_errors[mode], "message": "Graphics policy fixture"}})
                return
        if mode == "plugin_stall" and request["method"].startswith("plugin."):
            self.rfile.read()
            return
        if mode == "explanation_stall" and request["method"] == "agent.explain":
            self.rfile.read()
            return
        if mode == "prompt_stall" and request["method"] == "agent.prompt":
            self.rfile.read()
            return
        if mode == "prompt_oversized" and request["method"] == "agent.prompt":
            self.wfile.write(b"x" * (2 * 1024 * 1024 + 1))
            self.wfile.flush()
            self.rfile.read()
            return
        if mode == "large_history" and request["method"] == "pane.read":
            self.reply({"id": request["id"], "result": {"read": {
                "pane_id": request["params"]["pane_id"], "text": "h" * (3 * 1024 * 1024),
                "revision": 1, "truncated": False}}})
            return
        if mode == "drop_reply":
            return
        if mode == "unsupported":
            response = {"id": request["id"], "error": {
                "code": "invalid_request", "message": "Unknown method pane.scroll"}}
        elif request["method"] == "agent.prompt":
            response = {"id": request["id"], "result": {"type": "agent_prompted", "agent": {"pane_id": request["params"]["target"]}}}
        else:
            response = {"id": request["id"], "result": {"type": "pane_scrolled"}}
        self.wfile.write(json.dumps(response).encode() + b"\n")


class Server(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True


with Server(socket_path, Handler) as server:
    server.serve_forever()
