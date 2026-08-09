# herdr: terminal restore double-panics into SIGABRT

**Version:** herdr 0.8.0 (protocol 19), macOS 26.6 (Darwin 25.6.0), arm64

## Summary

Client cleanup calls `restore_terminal_state`, which calls
`ratatui::init::restore`. The restore writes to stderr. A failed write starts the
first panic. The panic hook calls `restore_terminal_state` again. Its failed
write starts a second panic, so Rust calls `abort()`.

The affected cleanup becomes `SIGABRT` / "Abort trap: 6". It creates a crash
report instead of a normal client exit. The reports cover terminal-attach and
server auto-detect client paths.

## Evidence

Seven crash reports occurred on 2026-08-08. Five occurred at 21:30:40.
One occurred at 21:31:16, and one occurred at 21:50:27.

Five stacks use `cli::run_terminal_command`. Two stacks use
`server::autodetect::auto_detect_launch`. All seven contain the same two restore
failures. From `herdr-2026-08-08-213040.ips`:

```
exception:   {"type": "EXC_CRASH", "signal": "SIGABRT"}
termination: {"code": 6, "namespace": "SIGNAL", "indicator": "Abort trap: 6"}
asi:         {"libsystem_c.dylib": ["abort() called"]}
```

The faulting thread follows this order from bottom to top:

```
herdr  ...cli::run_terminal_command                <- five reports
       ...or server::autodetect::auto_detect_launch <- two reports
herdr  ...client::run_client_with_mode
herdr  ...client::restore_terminal_state           <- normal cleanup
herdr  ...ratatui::init::restore
herdr  ...std::io::stdio::__eprint                  <- first failed write
herdr  ...std::panicking::panic_with_hook
herdr  ...client::run_client_with_modes::{closure#0}
herdr  ...client::restore_terminal_state           <- panic hook cleanup
herdr  ...ratatui::init::restore
herdr  ...std::io::stdio::__eprint                  <- second failed write
herdr  ...std::panicking::panic_with_hook
herdr  ...std::process::abort
libsystem_c.dylib  abort
```

## Reproduction

The stacks prove that client cleanup ran after stderr became unavailable. They
do not identify why stderr closed.

The terminal-attach bursts coincided with Rai replacing pooled
`terminal attach --takeover` clients. Rai also produced bursts when it exited.
The auto-detect reports show that the defect is not limited to the CLI attach
path.

## Impact

1. **Expected cleanup can become a crash.** A failed restore write creates an
   abort report instead of a normal exit.
2. **The first error is obscured.** The report ends at the second panic and
   abort. It does not record the failed-write error value.

## Suggested fix

Make terminal restore infallible in normal cleanup and the panic hook. Use
fallible writes and discard each restore error. Do not use output macros that
panic after a failed write.

Also make client displacement and shutdown use one normal cleanup path.
