#!/usr/bin/env python3
"""Isolated generation-one wire fixture. Never starts or controls a real Herdr."""
import json
from pathlib import Path
import socketserver
import struct
import sys
import threading

socket_path, mode, record_path = sys.argv[1:]


def integer(value):
    if value < 251:
        return bytes([value])
    if value <= 65535:
        return b"\xfb" + struct.pack("<H", value)
    return b"\xfc" + struct.pack("<I", value)


def blob(value):
    return integer(len(value)) + value


def text(value):
    return blob(value.encode())


def cell(symbol):
    return text(symbol) + integer(0x02010203) + b"\x00\x01\x00\x00"


def surface(projection=3, revision=1, popup=False, content_revision=1, width=1, history_rows=None):
    grid = integer(width) + cell("A") * width + integer(width) + b"\x01\x00\x00\x00"
    rect = b"\x00\x00" + integer(width) + b"\x01"
    scroll = b"\x00" if history_rows is None else b"\x01" + integer(0) + integer(history_rows - 1) + integer(1)
    pane = text("phone") + integer(content_revision) + rect + rect + b"\x00" + scroll + b"\x01\x00\x00\x00" + integer(width * 8) + integer(16)
    modal = b"\x01" + text("popup") + text("Test popup") + b"\x00\x00" + grid + b"\x00\x00\x08\x10" if popup else b"\x00"
    return b"\x0d" + text("boot") + integer(projection) + integer(revision) + grid + b"\x01" + pane + b"\x00" + modal + b"\x00\x00\x00"


def patch():
    return b"\x13" + text("boot") + b"\x03\x01\x02\x01\x00\x00\x01" + cell("B") + b"\x00\x00"


class Handler(socketserver.StreamRequestHandler):
    def send(self, payload):
        wire = struct.pack("<I", len(payload)) + payload
        # Fragment both the fixed-width frame prefix and the bincode strings.
        for offset in range(0, len(wire), 7):
            self.wfile.write(wire[offset:offset + 7])
            self.wfile.flush()

    def control(self, kind, value):
        self.send(b"\x14" + text(kind) + text(json.dumps(value)))

    def read_message(self):
        prefix = self.rfile.read(4)
        if not prefix:
            return None
        size = struct.unpack("<I", prefix)[0]
        assert size <= 2 * 1024 * 1024
        payload = self.rfile.read(size)
        with open(record_path, "a") as record:
            record.write(payload.hex() + "\n")
        return payload

    def history_width(self):
        revision, width = 4, 51
        projected = 20 if mode == "history_narrow" else 100
        advertised_rows = 1200 if mode == "history_truncated" else 400
        rows = 300 if mode == "history_invalid_row" else advertised_rows
        self.send(surface(content_revision=revision, width=projected, history_rows=advertised_rows))
        while True:
            message = self.read_message()
            if message is None:
                return
            assert message[0] == 15
            request = json.loads(message[message.index(b"{"):])
            assert request["method"] in ("pane.copy_motion", "pane.selection.read")
            params = request["params"]
            with open(record_path + ".history", "a") as record:
                record.write(json.dumps(request) + "\n")
            motion = request["method"] == "pane.copy_motion"
            if mode == "history_width_stale" and motion and revision == 4:
                revision, width = 6, 41
                self.send(surface(revision=2, content_revision=revision, width=projected, history_rows=advertised_rows))
            if params["content_revision"] != revision:
                response = dict(id=request["id"], error=dict(code="stale_content", message="pane content changed"))
            elif params["cursor"]["row"] >= rows:
                response = dict(id=request["id"], error=dict(code="copy_motion_unavailable", message="terminal row is unavailable"))
            elif motion:
                assert params["motion"] == "line_end" and params["cursor"]["col"] == 0
                result = dict(type="pane_copy_motion", pane_id="phone", cursor=dict(row=advertised_rows - 1, col=width - 1), content_revision=revision)
                if mode == "history_bad_pane": result["pane_id"] = "foreign"
                if mode == "history_bad_row": result["cursor"]["row"] -= 1
                if mode == "history_bad_revision": result["content_revision"] += 2
                if mode == "history_bad_type": result["type"] = "pane_selection"
                if mode == "history_bad_column": result["cursor"]["col"] = 65535
                if mode == "history_negative_column": result["cursor"]["col"] = -1
                if mode == "history_fractional_column": result["cursor"]["col"] = 1.5
                response = dict(id=request["id"], result=result)
            elif params["cursor"]["col"] >= width:
                response = dict(id=request["id"], error=dict(code="selection_unavailable", message="selection text is unavailable"))
            else:
                captured = "".join(f"row {index:03d} wrapped 👩🏽‍💻 tail\n" for index in range(params["anchor"]["row"], advertised_rows))
                if params["cursor"]["col"] < width - 1:
                    captured = captured[:-6]  # A narrow final column omits the last row's suffix.
                response = dict(id=request["id"], result=dict(type="pane_selection", pane_id="phone", text=captured))
            self.send(b"\x12" + text("boot") + text(request["id"]) + b"\x01" + blob(json.dumps(response).encode()))

    def handle(self):
        hello = self.read_message()
        assert hello and hello[0] == 20
        if mode == "startup_stall":
            self.rfile.read()
            return
        if mode == "oversized":
            self.wfile.write(struct.pack("<I", 2 * 1024 * 1024 + 1))
            self.wfile.flush()
            self.rfile.read()
            return
        welcome = dict(generation=1, server_version="future", snapshot_codec="shell.snapshot.v1",
                       surface_codec="shell.surface.v1", input_codec="shell.input.semantic.v1",
                       blob_codec="shell.blob.v1", methods=["client_shell.surface.set"], future={"optional": True})
        if mode == "plugin_pane":
            welcome["methods"].append("plugin.pane.open")
        if mode == "bad_codec":
            welcome["surface_codec"] = "unsupported"
        if mode.startswith("history_"):
            welcome["methods"].extend(["pane.copy_motion", "pane.selection.read"])
        self.control("endpoint.welcome.v1", welcome)
        self.control("future.optional", {"ignored": True})
        snapshot = dict(boot_id="boot", revision=3, focused_pane_id="phone")
        if mode == "mutation":
            snapshot["panes"] = [dict(pane_id="phone")]
            snapshot["agents"] = [dict(pane_id="phone", agent="codex")]
            if Path(record_path + ".mutation_started").exists():
                for _ in range(200):
                    if Path(record_path + ".api.accepted").exists():
                        break
                    threading.Event().wait(0.005)
            if Path(record_path + ".replacement").exists():
                snapshot["boot_id"] = "replacement"
            with open(record_path + ".verifications", "a") as record:
                record.write(json.dumps(dict(
                    boot=snapshot["boot_id"],
                    api_connected=Path(record_path + ".api.accepted").exists())) + "\n")
        if mode.startswith("history_"):
            snapshot["panes"] = [dict(pane_id="phone")]
        self.control("shell.snapshot.v1", snapshot)
        if mode != "mutation":
            self.control("shell.snapshot.v1", dict(boot_id="boot", revision=2, focused_pane_id="stale"))
        if mode == "new_boot":
            self.control("shell.snapshot.v1", dict(boot_id="replacement", revision=4))
        if mode == "write_stall":
            threading.Event().wait(10)
            return
        request = self.read_message()
        while (mode.startswith("history_") or mode == "mutation") and request is not None and request[0] != 15:
            request = self.read_message()
        if request is None:
            return
        assert request[0] == 15
        # The JSON string is the last field. Test requests contain no non-JSON braces before it.
        request_json = json.loads(request[request.index(b"{"):])
        if mode == "request_stall":
            self.rfile.read()
            return
        request_id = request_json["id"]
        response = json.dumps(dict(id=request_id, result=dict(type="client_shell_surface_set", active=False))).encode()
        if mode == "wrong_response":
            request_id = "another-request"
        for final, chunk in [(False, response[:11]), (True, response[11:])]:
            self.send(b"\x12" + text("boot") + text(request_id) + bytes([final]) + blob(chunk))
        if mode.startswith("history_") and mode != "history_race":
            return self.history_width()
        if mode == "history_race":
            self.send(surface(content_revision=4))
            attempt = 0
            while True:
                message = self.read_message()
                if message is None:
                    return
                if message[0] != 15:
                    continue
                request = json.loads(message[message.index(b"{"):])
                with open(record_path + ".history", "a") as record:
                    record.write(json.dumps(request) + "\n")
                attempt += 1
                if attempt == 1:
                    self.send(surface(revision=2, content_revision=6))
                    response = dict(id=request["id"], error=dict(code="stale_content", message="pane content changed"))
                elif request["method"] == "pane.copy_motion":
                    response = dict(id=request["id"], result=dict(type="pane_copy_motion", pane_id="phone", cursor=dict(row=0, col=0), content_revision=6))
                else:
                    response = dict(id=request["id"], result=dict(type="pane_selection", pane_id="phone", text="stable phone history 👩🏽‍💻"))
                self.send(b"\x12" + text("boot") + text(request["id"]) + b"\x01" + blob(json.dumps(response).encode()))
        if mode == "plugin_pane":
            self.send(surface())
            while True:
                message = self.read_message()
                if message is None:
                    return
                if message[0] != 15:
                    continue
                request = json.loads(message[message.index(b"{"):])
                with open(record_path + ".plugin", "a") as record:
                    record.write(json.dumps(request) + "\n")
                response = dict(id=request["id"], result=dict(type="plugin_pane_opened"))
                self.send(b"\x12" + text("boot") + text(request["id"]) + b"\x01" + blob(json.dumps(response).encode()))
        if mode in ("surface", "input_stall", "input_record", "paste", "window_title", "mutation"):
            self.send(surface())
        if mode == "surface":
            self.send(patch())
        if mode == "window_title":
            self.send(b"\x06\x01" + text("Rai scoped title"))
            self.read_message()
            self.send(b"\x06\x00")
        if mode == "input_record":
            while self.read_message() is not None:
                pass
            return
        if mode == "input_stall":
            threading.Event().wait(10)
            return
        if mode == "paste":
            self.read_message()
        if mode == "popup":
            self.send(surface(popup=True))
            self.read_message()
            self.send(surface(revision=2))
        if mode in ("input_metadata", "input_navigation"):
            self.send(surface())
            focus = "other" if mode == "input_navigation" else "phone"
            self.control("shell.snapshot.v1", dict(boot_id="boot", revision=4, focused_pane_id=focus))
            self.control("shell.snapshot.v1", dict(boot_id="boot", revision=5, focused_pane_id="phone"))
            self.send(surface(projection=5, revision=2))
            self.read_message()
        self.rfile.read()


class Server(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True


with Server(socket_path, Handler) as server:
    server.serve_forever()
