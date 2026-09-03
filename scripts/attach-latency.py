#!/usr/bin/env python3
"""Measure keystroke -> echo latency through `herdr terminal attach` on a pane at a shell prompt.
Usage: attach_latency.py <socket_path> <terminal_id> [n]
"""
import os, pty, sys, time, select, statistics, signal, fcntl, termios, struct

sock, term = sys.argv[1], sys.argv[2]
n = int(sys.argv[3]) if len(sys.argv) > 3 else 25
env = dict(os.environ); env["HERDR_SOCKET_PATH"] = sock; env["TERM"] = "xterm-256color"
pid, fd = pty.fork()
if pid == 0:
    fcntl.ioctl(sys.stdout.fileno(), termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    os.execvpe("herdr", ["herdr", "terminal", "attach", term, "--takeover"], env)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))

def drain(timeout):
    end = time.time() + timeout; out = b""
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], max(0, end - time.time()))
        if not r: break
        try: out += os.read(fd, 65536)
        except OSError: break
    return out

first = drain(3.0)
print("initial bytes:", len(first), "| sample:", first[:100])
lat = []; sample = b""
for i in range(n):
    ch = chr(ord('a') + (i % 26)).encode()
    t0 = time.perf_counter(); os.write(fd, ch); buf = b""; seen = False
    while time.perf_counter() - t0 < 2.0:
        r, _, _ = select.select([fd], [], [], 0.5)
        if not r: continue
        try: buf += os.read(fd, 65536)
        except OSError: break
        if ch in buf:
            lat.append((time.perf_counter() - t0) * 1000); seen = True; break
    if not seen:
        lat.append(float("nan")); sample = buf[:200]
    time.sleep(0.15)
os.write(fd, b"\x15"); drain(0.5)
good = sorted(x for x in lat if x == x)
if good:
    p90 = good[max(0, int(len(good) * 0.9) - 1)]
    print(f"keystroke -> echo via herdr attach: n={len(good)} median={statistics.median(good):.1f} ms p90={p90:.1f} ms min={good[0]:.1f} ms max={good[-1]:.1f} ms")
else:
    print("no echoes seen; last sample:", sample)
try: os.kill(pid, signal.SIGTERM)
except Exception: pass
