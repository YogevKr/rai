Native macOS client for [herdr](https://herdr.dev). Universal binary (Apple Silicon + Intel), macOS 14+.

### New in this release

- **Lower CPU use for hidden terminals.** Rai disconnects hidden terminal
  display clients after one second. Agents keep running in Herdr, and Rai
  keeps cached scrollback. Opening a tab reconnects its display.
- **Reliable reconnects.** Control keys entered during reconnection reach
  the terminal unchanged. Rai also cleans up stopped display processes.

No Rai Remote change in this release. The current TestFlight build (35) keeps
working, and the bridge protocol stays 6.

### Install

```sh
brew install --cask yogevkr/tap/rai
```

Or download the `.dmg` below, open it, and drag **Rai** into **Applications**.

Then open rai — it starts the herdr server itself if one is not running.

Prefer to build it yourself? `git clone` and run `./scripts/bundle.sh`.
