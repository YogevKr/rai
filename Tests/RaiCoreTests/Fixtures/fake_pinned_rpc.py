#!/usr/bin/env python3
import json
import select
import socket
import socketserver
import sys

path, mode, record = sys.argv[1:]


class MutationHandler(socketserver.StreamRequestHandler):
    def handle(self):
        line = self.rfile.readline() if select.select([self.request], [], [], 0.05)[0] else None
        if line and json.loads(line)["method"] == "pane.graphics.info":
            request = json.loads(line)
            with open(record + ".reads", "ab") as file:
                file.write(line)
            self.wfile.write(json.dumps({"id": request["id"], "result": {"type": "pane_graphics_info"}}).encode() + b"\n")
            self.wfile.flush()
            return
        with open(record + ".connections", "a") as file:
            file.write("accepted\n")
        with open(record + ".accepted", "w") as file:
            file.write("ready\n")
        if line is None:
            line = self.rfile.readline()
        if not line:
            with open(record + ".closed_without_write", "a") as file:
                file.write("closed\n")
            return
        with open(record, "ab") as file:
            file.write(line)
        request = json.loads(line)
        if mode == "mutation_drop":
            return
        result = {"type": "agent_prompted"} if request["method"] == "agent.prompt" else {"type": "ok"}
        self.wfile.write(json.dumps({"id": request["id"], "result": result}).encode() + b"\n")
        self.wfile.flush()


if mode.startswith("mutation_"):
    with socketserver.ThreadingUnixStreamServer(path, MutationHandler) as server:
        server.daemon_threads = True
        server.serve_forever()
    sys.exit(0)

with socket.socket(socket.AF_UNIX) as listener:
    listener.bind(path)
    listener.listen()
    with listener.accept()[0] as connection:
        line = connection.makefile('rb').readline()
        if line:
            with open(record, 'wb') as file:
                file.write(line)
            request = json.loads(line)
            if mode == 'stall':
                connection.recv(1)
            else:
                response = {'id': 'wrong' if mode == 'wrong' else request['id'],
                            'result': {'agent': {'pane_id': 'w1:p1'}}}
                connection.sendall(json.dumps(response).encode() + b'\n')
