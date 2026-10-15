#!/usr/bin/env python3
"""Query terminal colors inside one owned native lab pane."""
import json
import os
from pathlib import Path
import select
import sys
import termios
import time
import tty

fd = sys.stdin.fileno()
previous = termios.tcgetattr(fd)
received = b''
try:
    tty.setraw(fd)
    os.write(sys.stdout.fileno(), b'\x1b]10;?\x1b\\\x1b]11;?\x1b\\\x1b]4;0;?\x1b\\\x1b]4;255;?\x1b\\')
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        if not select.select([fd], [], [], 0.1)[0]:
            continue
        received += os.read(fd, 4096)
        if received.count(b'\x1b\\') + received.count(b'\x07') >= 4:
            break
finally:
    termios.tcsetattr(fd, termios.TCSANOW, previous)
Path(sys.argv[1]).write_text(json.dumps({'response': received.decode('ascii')}))
