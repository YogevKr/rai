Native macOS client for [herdr](https://herdr.dev). Universal binary (Apple Silicon + Intel), macOS 14+.

### New in this release

- **rai starts herdr for you.** Open rai with no herdr server running and it
  starts the herd it points at, waits for it, and connects — no `herdr server`
  in a terminal first. Quitting rai leaves that server and your agents running,
  the way herdr always worked.
- A herd rai cannot identify — a custom `HERDR_SOCKET_PATH`, or a remote herd
  over SSH — is left alone.

### Fixed in this release

- **Starting the default session no longer creates a second herd.** Picking the
  stopped default session in the session switcher ran `herdr --session default
  server`, which made a separate herd under `sessions/default` instead of the
  real one.

### Install

```sh
brew install --cask yogevkr/tap/rai
```

Or download the `.dmg` below, open it, and drag **Rai** into **Applications**.

Then open rai — it starts the herdr server itself if one is not running.

Prefer to build it yourself? `git clone` and run `./scripts/bundle.sh`.
