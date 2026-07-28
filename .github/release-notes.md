Native macOS client for [herdr](https://herdr.dev). Universal binary (Apple Silicon + Intel), macOS 14+.

### New in this release

- **Phone pushes wait until you leave the Mac.** If an agent needs you while
  you're actively working at the Mac, the Mac notification fires but the
  phone stays quiet; handle the pane at the desk and the phone never buzzes.
  Step away with the pane still waiting and the push arrives once you've been
  idle ~2 minutes. Toggle in Settings → Notifications (on by default).

### Install

1. Download the `.dmg` below, open it, and drag **Rai** into **Applications**.
2. rai isn't notarized yet (no paid Apple Developer account), so on first launch
   macOS Gatekeeper will block it. Do **one** of:
   - **Right-click** `Rai.app` → **Open** → **Open**, or
   - run `xattr -dr com.apple.quarantine /Applications/Rai.app` and launch normally.
3. Make sure a herdr server is running (`herdr server`), then open rai.

Prefer to build it yourself? `git clone` and run `./scripts/bundle.sh`.
