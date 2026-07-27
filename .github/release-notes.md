Native macOS client for [herdr](https://herdr.dev). Universal binary (Apple Silicon + Intel), macOS 14+.

### New in this release

- **One continuous dark surface** — the dark theme's window base now matches the
  terminal background, so the strip above the panes and the gutter under the
  sidebar no longer read as a darker band.
- **iOS companion: TestFlight-ready project** — the `ios/` app moved to the
  `com.whetstone` bundle prefix with automatic signing, gained an app icon, and
  declares the export-compliance exemption needed for TestFlight uploads.

### Install

1. Download the `.dmg` below, open it, and drag **Rai** into **Applications**.
2. rai isn't notarized yet (no paid Apple Developer account), so on first launch
   macOS Gatekeeper will block it. Do **one** of:
   - **Right-click** `Rai.app` → **Open** → **Open**, or
   - run `xattr -dr com.apple.quarantine /Applications/Rai.app` and launch normally.
3. Make sure a herdr server is running (`herdr server`), then open rai.

Prefer to build it yourself? `git clone` and run `./scripts/bundle.sh`.
