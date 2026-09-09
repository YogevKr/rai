#!/usr/bin/env python3
"""Review closure socket ownership without starting Herdr."""
import json
import socketserver
import struct
import sys

socket_path, mode, record_path = sys.argv[1:]
connections = 0


def integer(value):
    return bytes([value]) if value < 251 else b'\xfb' + struct.pack('<H', value)


def blob(value):
    return integer(len(value)) + value


def text(value):
    return blob(value.encode())


def workspace(identity, linked):
    return dict(workspace_id=identity, number=1, label=identity, focused=False,
                pane_count=1, tab_count=1, active_tab_id=identity + ':t1', agent_status='idle',
                worktree=dict(repo_key='repo', repo_name='repo', checkout_path='/tmp/' + identity,
                              is_linked_worktree=linked))


class Handler(socketserver.StreamRequestHandler):
    def send(self, payload):
        self.wfile.write(struct.pack('<I', len(payload)) + payload)
        self.wfile.flush()

    def control(self, kind, value):
        self.send(b'\x14' + text(kind) + text(json.dumps(value)))

    def receive(self):
        prefix = self.rfile.read(4)
        if not prefix:
            return None
        return self.rfile.read(struct.unpack('<I', prefix)[0])

    def handle(self):
        global connections
        connections += 1
        number = connections
        if not self.receive():
            return
        with open(record_path, 'a') as record:
            record.write(json.dumps(dict(connection=number)) + '\n')
        boot = 'reviewed' if number == 1 else 'replacement'
        self.control('endpoint.welcome.v1', dict(generation=1, server_version='0.9',
            snapshot_codec='shell.snapshot.v1', surface_codec='shell.surface.v1',
            input_codec='shell.input.semantic.v1', blob_codec='shell.blob.v1', methods=['workspace.close', 'client_shell.surface.set']))
        remaining = [workspace('w1', False), workspace('w2', True)]
        self.control('shell.snapshot.v1', dict(boot_id=boot, revision=1, workspaces=remaining))
        activation = self.receive()
        activation = json.loads(activation[activation.index(b'{"'):])
        assert activation['method'] == 'client_shell.surface.set' and activation['params']['active'] is True
        with open(record_path, 'a') as record:
            record.write(json.dumps(activation) + '\n')
        response = json.dumps(dict(id=activation['id'], result=dict(type='client_shell_surface_set', active=True))).encode()
        self.send(b'\x12' + text(boot) + text(activation['id']) + b'\x01' + blob(response))
        for revision in [2, 3, 4]:
            payload = self.receive()
            if payload is None:
                return
            request = json.loads(payload[payload.index(b'{"'):])
            with open(record_path, 'a') as record:
                record.write(json.dumps(request) + '\n')
            if request['method'] == 'client_shell.surface.set':
                assert request['params']['active'] is False
                response = json.dumps(dict(id=request['id'], result=dict(type='client_shell_surface_set', active=False))).encode()
                self.send(b'\x12' + text(boot) + text(request['id']) + b'\x01' + blob(response))
                self.rfile.read()
                return
            identity = request['params']['workspace_id']
            remaining = [item for item in remaining if item['workspace_id'] != identity]
            if mode == 'membership' and revision == 2:
                remaining.append(workspace('w3', True))
            self.control('shell.snapshot.v1', dict(boot_id=boot, revision=revision, workspaces=remaining))
            response = json.dumps(dict(id=request['id'], result=dict(type='ok'))).encode()
            self.send(b'\x12' + text(boot) + text(request['id']) + b'\x01' + blob(response))
            if mode == 'restart':
                return


class Server(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True


with Server(socket_path, Handler) as server:
    server.serve_forever()
