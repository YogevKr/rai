Native macOS client for [herdr](https://herdr.dev). Universal binary (Apple Silicon + Intel), macOS 14+.

### New in this release

- **Faster typing during output.** Rai processes terminal output without
  waiting for a display update. Keyboard echoes can follow background output
  without waiting for another frame.
- **Update popup.** A solid popup shows **Update** and **Skip** when a newer
  version is available. Update verifies the download, installs the signed
  release, and restarts Rai. Your agents keep running in Herdr.
- **Skip one version.** Skip hides that version across launches. Later
  versions still appear. Use **Rai → Check for Updates…** to check again,
  including a version you skipped.

Rai checks for updates after launch and every six hours. Installation requires
a writable Applications folder. The installer keeps the previous app for recovery.

### Install

```sh
brew install --cask yogevkr/tap/rai
```

Or download the `.dmg` below, open it, and drag **Rai** into **Applications**.

Then open rai — it starts the herdr server itself if one is not running.

Prefer to build it yourself? `git clone` and run `./scripts/bundle.sh`.
