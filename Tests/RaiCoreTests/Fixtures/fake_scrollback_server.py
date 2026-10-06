#!/usr/bin/env python3
"""Serve Herdr pane.read responses with the RPC source names."""
import json
import socket
import sys

with socket.socket(socket.AF_UNIX) as listener:
    listener.bind(sys.argv[1])
    listener.listen()
    with listener.accept()[0] as connection:
        for line in connection.makefile("rb"):
            request = json.loads(line)
            params = request["params"]
            source = params.get("source")
            response = {"id": request["id"]}
            if request["method"] != "pane.read" or source not in ("recent_unwrapped", "visible"):
                response["error"] = {"code": "invalid_request", "message": "Invalid pane.read source"}
            else:
                text = "prompt" if source == "visible" else "older output\r\nprompt"
                response["result"] = {"type": "pane_read", "read": {
                    "pane_id": params["pane_id"], "text": text, "revision": 7, "truncated": False,
                }}
            connection.sendall(json.dumps(response).encode() + b"\n")
