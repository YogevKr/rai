# Unix socket line reads

`UnixSocket.readLine` searched the complete buffered response after every 16 KiB read.
An unterminated 2 MiB response therefore repeated work until the request timeout.

The reader now records the number of bytes already searched.
Each new read scans only its appended range.
Data indices are derived again after appends, so buffered data remains safe.
The reader still handles fragmented lines, coalesced lines, EINTR, closed sockets, and per-call byte limits.
It keeps buffered data after a limit error, as before.

## Verification

The focused gate passed 23 tests on October 8, 2026.
This includes all `HerdrScrollTransportTests` and seven dedicated `UnixSocketLineTests`.

The existing oversized prompt regression changed from a timeout after 6.109 seconds to a passing result in 0.133 seconds.
The dedicated 2 MiB unterminated line read changed from 2.791 seconds to 0.0219 seconds.
The dedicated test prints elapsed time but sets no universal timing threshold.

The new tests use two task-owned Unix socket endpoints.
They do not start Herdr, connect to a user session, or change external state.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test -j 2 --filter 'UnixSocketLineTests|HerdrScrollTransportTests'
```

No request timeout, frame limit, write replay, socket closure, or response parser changed.
