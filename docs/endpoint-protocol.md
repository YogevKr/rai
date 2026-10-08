# Endpoint health and host theme

Rai implements these contracts in Swift. Herdr owns processes. Rai owns display and navigation.
The machine, space, tab, and pane hierarchy remains unchanged.

The release gate passed before these changes started.
Run `37759770305` released commit `a299417983ea322bc79a62c840d88246b9d2749d` successfully.

## Protocol evidence

The installed Herdr reports version `0.9.3` and endpoint generation `1`.
Its client status advertises `health_check`.
Herdr's `v0.9.3` source defines the native theme tags and health control names.

The independent reference is [penso/herdr-gpui](https://github.com/penso/herdr-gpui/tree/3871183cac85d93ec3624329a62acb9f63172851).
Its host-theme ordering informed this implementation. Rai includes no reference code or new dependency.

## Public APIs

```swift
HerdrEndpointConnection(
    healthQuietInterval: Duration = .seconds(5),
    healthTimeout: Duration = .seconds(10)
)

var supportsHealthChecks: Bool { get }

func checkHealth(timeout: Duration = .seconds(10)) async throws

EndpointHostTheme(
    foreground: UInt32,
    background: UInt32,
    palette: [UInt32],
    appearance: EndpointHostTheme.Appearance
) throws

func setHostTheme(
    _ theme: EndpointHostTheme,
    expectedBootID: String,
    timeout: Duration = .seconds(10)
) async throws
```

Read `supportsHealthChecks` through the connection actor after its welcome arrives.
Health timing values must exceed zero.
Use the default timing in the window worker. Shorter timing supports isolated regression tests.

The window supplies actual terminal colors through `EndpointHostTheme`.
Colors use `0xRRGGBB`. The palette contains exactly 256 colors. Appearance accepts `.dark` and `.light`.
Theme construction rejects incomplete palettes and values above `0xffffff`.
Theme preferences alone do not describe the terminal's actual colors.

The window must call `setHostTheme` after each new connection completes.
It must call the same method when actual colors or appearance change.
Capture the current boot ID for each call. A replaced connection needs a new capture.

## Capability behavior

| Contract | Requirement | Behavior when absent |
| --- | --- | --- |
| Health controls | Welcome capability `health_check` | Disable automatic probes; reject explicit probes without closing transport. |
| Host theme | Negotiated generation one | Send native updates without a separate theme capability. |
| Endpoint operations | Welcome method list | Reject unsupported methods before writing. |

A valid operation error rejects only that operation. It does not close the transport or clear the theme cache.
A caller must not classify this rejection as a machine outage.
A machine without `health_check` has no endpoint health guarantee.
An SSH master process cannot establish daemon health.

## Health flow

```text
complete accepted message
  finish current probe
  start quiet deadline
quiet deadline expires
  queue endpoint.health.ping.v1
  start probe deadline
complete accepted message
  finish current probe
probe deadline expires
  close connection
  fail streams and pending work
```

The ping uses an empty data string. Herdr returns `endpoint.health.pong.v1`.
Any complete accepted message can satisfy a probe, including an old snapshot from the same boot.
Old snapshots never replace current selection. A changed boot fails the connection.
Malformed messages cannot satisfy a probe.

Partial frame headers and bodies keep their framing. They cannot extend the probe deadline.
Closing the socket interrupts its blocked reader and writer.
Health traffic cannot extend startup, request, or input deadlines.

`checkHealth` sends an immediate probe or joins the current probe.
Each caller has its own deadline. No caller can extend the shared probe deadline.
The connection bounds waiting callers at 64. Cancellation closes the connection.
Automatic checks require no window timer.

## Theme flow

The first call sends appearance, foreground, background, then the complete palette.
Initial appearance prevents Herdr from inferring appearance from the background.
Later calls send only changed foreground, background, and palette entries.
They send changed appearance last, after its colors reach the daemon.
Unchanged calls write nothing. Identity and cancellation checks still apply.

Native client tag `17` carries theme updates.
Update tags are `0` for default color, `1` for palette, and `2` for appearance.
Default color tags are `0` for foreground and `1` for background.
Appearance tags are `0` for dark and `1` for light. Each color carries three RGB bytes.

One writer batch keeps each theme update group together.
The writer orders that batch with input, resize, operation, and health frames.
The existing 64-write bound also covers theme batches.
Method completion confirms socket writes. It does not acknowledge daemon application.

Every new connection starts with an empty theme cache.
Failure clears that connection's cache and pending work. Rai never retries its writes.
Reconnect must construct a new `HerdrEndpointConnection`. It must not replay input or operations.

## Verification

`EndpointHealthThemeTests` uses a dedicated fake Unix-socket peer for each test.
It covers quiet probes, stalls, partial frames, old messages, malformed data, cancellation, and operation rejection.
It also checks native theme bytes, ordering, unchanged values, stale targets, and reconnect reset.

The native test requires `RAI_ENDPOINT_TEST_ROOT` with an owned app-lab marker.
It uses only that lab's client socket and pane.
It checks health and terminal OSC queries for foreground, background, and palette entries.

The October 8, 2026 check passed all 18 focused tests, including the native test.
The full RaiCore suite passed 629 tests, with one skipped and no failures.
The owned native lab is `/private/tmp/rai09-9_vexk1t`.
Its OSC records show both initial colors and changed background colors.
Logs are `protocol-focused.log` and `protocol-core.log` in that lab.

Run focused and core checks with Xcode and two compilation jobs:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --scratch-path .build-tests -j 2 --filter EndpointHealthThemeTests

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --scratch-path .build-tests -j 2 --filter RaiCoreTests
```

The controller must verify window integration and actual appearance changes.
This core task does not establish authenticated Codex, cloud, physical-device, or full app behavior.
