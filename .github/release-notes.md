Native macOS client for [herdr](https://herdr.dev). Universal binary (Apple Silicon + Intel), macOS 14+.

### New in this release

- **Less history traffic.** The Mac checks retained phone history and skips
  sending it when the content has not changed. Update both apps for this benefit.
- **Connection checks.** The Mac handles WebSocket ping and pong messages
  without reporting them as invalid requests.

### iOS companion build 36

- **Retained threads.** The phone retains three recent terminal views.
  Returning to a thread shows its text and scroll position before the Mac replies.
  Hidden views detach their display streams. Your agents keep running in Herdr.
- **Slow connections.** Longer connection deadlines and fewer history reads
  support weak connections. The phone pauses retries while offline and reconnects when the network returns.
- **Terminal display.** Horizontal scrolling uses one scroll view to prevent
  left-edge clipping. History updates and resizing preserve the text you are reading.
- **Reconnect banner.** The banner waits three seconds after a connection failure.
  Recovery cancels it. Pairing failures show the repair action immediately.

The phone receives changed history as a complete replacement.
Older app versions remain compatible. The history traffic reduction requires this Mac release and iOS build 36.

### Install

If you use 0.1.49, install this release from the DMG or Homebrew.
Its in-app update can stall during shutdown. Version 0.1.50 fixed that issue.

```sh
brew install --cask yogevkr/tap/rai
```

Or download the `.dmg` below, open it, and drag **Rai** into **Applications**.

Then open rai — it starts the herdr server itself if one is not running.

Prefer to build it yourself? `git clone` and run `./scripts/bundle.sh`.
