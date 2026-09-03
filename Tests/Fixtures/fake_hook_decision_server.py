#!/usr/bin/env python3
import json
import os
import socket
import sys
import time

socket_path, decision = sys.argv[1:3]
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(socket_path)
server.listen(1)
client, _ = server.accept()
with client:
    request = client.makefile("rb").readline(262145)
    json.loads(request)
    if decision == "timeout":
        time.sleep(4)
    else:
        response = {"decision": decision}
        if decision == "deny":
            response["message"] = "Denied by phone"
        client.sendall(json.dumps(response).encode() + b"\n")
server.close()
try:
    os.unlink(socket_path)
except FileNotFoundError:
    pass
