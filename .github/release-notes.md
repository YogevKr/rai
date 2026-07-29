Native macOS client for [herdr](https://herdr.dev). Universal binary (Apple Silicon + Intel), macOS 14+.

### New in this release

- **rai is now signed and notarized by Apple.** Gatekeeper accepts it on the
  first launch — no right-click → Open, no `xattr` incantation. The notarization
  ticket is stapled into both the app and the disk image, so it works offline.
- **New tabs open next to the focused tab** instead of at the end of the space.
  Applies to Cmd+T, the app and pane menus, and a tab row's context menu;
  "New Tab in Space" from a space header still appends at the end.

### Upgrading

The app is now signed with a Developer ID instead of ad-hoc, so macOS treats it
as a new identity and resets its privacy grants. If you use the Codex Micro pad,
re-approve rai under **System Settings → Privacy & Security → Input Monitoring**
after updating.

### Install

```sh
brew install --cask yogevkr/tap/rai
```

Or download the `.dmg` below, open it, and drag **Rai** into **Applications**.

Then make sure a herdr server is running (`herdr server`), and open rai.

Prefer to build it yourself? `git clone` and run `./scripts/bundle.sh`.
