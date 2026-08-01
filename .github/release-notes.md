Native macOS client for [herdr](https://herdr.dev). Universal binary (Apple Silicon + Intel), macOS 14+.

### Fixed in this release

- **No keychain prompt when rai starts.** rai read its push auth key from the
  keychain at launch, on the main thread, before it had drawn a window — so a
  freshly installed build could put a password box in front of an app that
  showed nothing, and hold there until you answered. The key is only needed to
  send a push or to edit it in Settings, so it is read there instead. Checking
  whether push is set up no longer opens the keychain at all.

### Install

```sh
brew install --cask yogevkr/tap/rai
```

Or download the `.dmg` below, open it, and drag **Rai** into **Applications**.

Then open rai — it starts the herdr server itself if one is not running.

Prefer to build it yourself? `git clone` and run `./scripts/bundle.sh`.
