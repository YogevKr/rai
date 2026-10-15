#!/usr/bin/env python3
"""Owned Unix-socket peer for health and host-theme regression tests."""
import json
from pathlib import Path
import socketserver
import struct
import sys
import time

socket_path, mode, record_path = sys.argv[1:]


def integer(value):
    if value < 251:
        return bytes([value])
    if value <= 65535:
        return b'\xfb' + struct.pack('<H', value)
    return b'\xfc' + struct.pack('<I', value)


def blob(value):
    return integer(len(value)) + value


def text(value):
    return blob(value.encode())


def control(kind, value):
    return b'\x14' + text(kind) + text(value)


class Peer(socketserver.StreamRequestHandler):
    def send(self, payload):
        self.wfile.write(struct.pack('<I', len(payload)) + payload)
        self.wfile.flush()

    def read_message(self):
        prefix = self.rfile.read(4)
        if not prefix:
            return None
        assert len(prefix) == 4
        size = struct.unpack('<I', prefix)[0]
        assert size <= 2 * 1024 * 1024
        payload = self.rfile.read(size)
        assert len(payload) == size
        with open(record_path, 'a') as record:
            record.write(payload.hex() + '\n')
        return payload

    def handle(self):
        try:
            self.run()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def run(self):
        assert self.read_message()[0] == 20
        welcome = dict(generation=1, server_version='0.9.3', snapshot_codec='shell.snapshot.v1',
                       surface_codec='shell.surface.v1', input_codec='shell.input.semantic.v1',
                       blob_codec='shell.blob.v1', methods=['client_shell.surface.set'],
                       capabilities=[] if mode in ('no_capability', 'input_order') else ['health_check'])
        self.send(control('endpoint.welcome.v1', json.dumps(welcome)))
        if mode != 'startup_health':
            self.send(control('shell.snapshot.v1', json.dumps(dict(boot_id='boot', revision=3, focused_pane_id='pane'))))
        if mode == 'input_order':
            cell = text('A') + integer(0x02010203) + b'\x00\x01\x00\x00'
            grid = b'\x01' + cell + b'\x01\x01\x00\x00\x00'
            rect = b'\x00\x00\x01\x01'
            pane = text('pane') + b'\x01' + rect + rect + b'\x00\x00\x01\x00\x00\x00\x08\x10'
            self.send(b'\x0d' + text('boot') + b'\x03\x01' + grid + b'\x01' + pane + b'\x00\x00\x00\x00\x00')
        if mode == 'partial_before_probe':
            payload = control('future.optional', '{}')
            wire = struct.pack('<I', len(payload)) + payload
            self.wfile.write(wire[:6])
            self.wfile.flush()
            time.sleep(0.12)
            self.wfile.write(wire[6:])
            self.wfile.flush()
        while (message := self.read_message()) is not None:
            if message[0] == 20:
                assert message == control('endpoint.health.ping.v1', '')
                if mode == 'stall':
                    continue
                if mode in ('partial_prefix', 'partial_payload', 'dribble'):
                    wire = struct.pack('<I', 100) + b'\x14\x00'
                    length = 2 if mode == 'partial_prefix' else len(wire)
                    self.wfile.write(wire[:length])
                    self.wfile.flush()
                    if mode == 'dribble':
                        for _ in range(30):
                            time.sleep(0.03)
                            self.wfile.write(b'x')
                            self.wfile.flush()
                    continue
                if mode == 'malformed':
                    self.send(b'\x14\x01\xff\x00')
                elif mode == 'old_snapshot':
                    self.send(control('shell.snapshot.v1', '{"boot_id":"boot","revision":1,"focused_pane_id":"old"}'))
                elif mode == 'new_boot':
                    self.send(control('shell.snapshot.v1', '{"boot_id":"changed","revision":4}'))
                else:
                    if mode == 'delayed_pong':
                        time.sleep(0.12)
                    self.send(control('endpoint.health.pong.v1', ''))
            elif message[0] == 15:
                request = json.loads(message[message.index(b'{'):])
                if mode == 'request_stall':
                    continue
                response = dict(id=request['id'], result=dict(active=False))
                if mode == 'reject':
                    response = dict(id=request['id'], error=dict(code='focus_rejected', message='Not selected'))
                self.send(b'\x12' + text('boot') + text(request['id']) + b'\x01' + blob(json.dumps(response).encode()))
            else:
                assert message[0] in (12, 13, 17)


Path(record_path).touch()
with socketserver.UnixStreamServer(socket_path, Peer) as server:
    server.serve_forever()
