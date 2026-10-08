# Sidebar path lookup performance

Tab selection in 0.1.92 repeated filesystem path checks while SwiftUI rebuilt sidebar rows.
The installed app sample contained 105 of 1,217 main-thread samples inside these checkout lookups.
Those calls reached `URL.resolvingSymlinksInPath`, `lstat`, and `getattrlist`.

The sidebar now uses the exact path from its Herdr snapshot.
The background Git cache resolves local symlinks and returns status entries under canonical paths and source aliases.
This keeps branch labels and repository groups correct for symlink checkouts.
Remote models skip local Git polling, and remote sidebar paths never resolve against the Mac filesystem.
Directory labels now use string operations instead of file URL initialization.

Alias maps contain only paths from the current request.
Each background request checks symlink targets again, so a changed target cannot use a stale global mapping.
This change does not modify terminal clients, output parsing, input, SSH transport, or selection behavior.

## Verification

The focused suite passed all 17 tests on October 8, 2026.
New regression cases cover symlink status lookup, repository grouping, symlink target changes, source alias removal, and repeated rendering.
Remote cases cover local symlink collisions, missing paths, home-relative paths, and paths containing `..`.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
RAI_SIDEBAR_PERFORMANCE_PROBE=1 \
swift test -j 2 --filter WorkspaceSidebarTests
```

The optional probe uses 40 spaces, 80 tabs, and 100 redraw passes after five warmup passes.
Each pass builds both sidebar entry lists and reads each tab and space status.
It checks the same result checksum, 56,000, after timing.
It reports process CPU time and elapsed time without enforcing a machine-specific threshold.

## Paired measurements

A standalone copy of the probe linked the baseline and changed `RaiCore` debug objects.
Both drivers used `swiftc -O`, identical fixtures, and the same Mac.
The order alternated to reduce order effects.
Other build processes shared the Mac during measurement.

| Run | Version | CPU seconds | Elapsed seconds | Checksum |
| --- | --- | ---: | ---: | ---: |
| 1 | 0.1.92 | 0.799940 | 0.800437 | 56,000 |
| 1 | Changed | 0.218584 | 0.218972 | 56,000 |
| 2 | Changed | 0.218071 | 0.220287 | 56,000 |
| 2 | 0.1.92 | 0.811977 | 0.819427 | 56,000 |
| 3 | 0.1.92 | 0.985481 | 0.990738 | 56,000 |
| 3 | Changed | 0.176892 | 0.179596 | 56,000 |

Median CPU time fell from 0.812 seconds to 0.218 seconds, a 73 percent reduction for this fixture.
The checked-in XCTest probe also passed, with 0.358 CPU seconds and the same checksum.
These measurements cover sidebar computation, not complete tab-switch latency or physical display presentation.
No authenticated agent, cloud session, or iOS runtime test ran in this worktree.

Local evidence remains in these task-owned files:

- `/private/tmp/rai-0192-latency-idle.sample.txt`
- `/private/tmp/rai-sidebar-row-benchmark.swift`
- `/private/tmp/rai-sidebar-row-comparison.txt`
- `/private/tmp/rai-sidebar-focused.log`
