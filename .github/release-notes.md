Native macOS client for [herdr](https://herdr.dev). Universal binary (Apple Silicon + Intel), macOS 14+.

### New in this release

- **Open repos as spaces from the command palette.** The palette now scans
  your repo folders and opens any repo as a new space. Results rank by
  recency, match across name and path — including paths typed in `~` form —
  and modifier keys pick how the match opens. Return always takes the top
  match, and the list no longer scrolls under a resting cursor.
- **Closed tabs come back whole.** Reopen a closed tab and it returns with
  its full split shape, not a single pane. The reopen stack survives app
  restarts, is kept per herd, and a reopened agent only resumes when its
  session or command line proves it is the same agent.

### Fixed in this release

- **Remote herds render again on herdr 0.7.5.** herdr 0.7.5 moved terminal
  attach onto a second socket next to the RPC one. rai's SSH tunnel only
  forwarded the first, so a remote connection looked healthy but every pane
  failed to attach. The tunnel now forwards both sockets.

### Install

```sh
brew install --cask yogevkr/tap/rai
```

Or download the `.dmg` below, open it, and drag **Rai** into **Applications**.

Then open rai — it starts the herdr server itself if one is not running.

Prefer to build it yourself? `git clone` and run `./scripts/bundle.sh`.
