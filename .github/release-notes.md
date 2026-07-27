Native macOS client for [herdr](https://herdr.dev). Universal binary (Apple Silicon + Intel), macOS 14+.

### New in this release — iPhone companion

rai now bridges your herd to a native **iOS companion app** (`ios/`, build it with
Xcode — see [docs/ios.md](https://github.com/YogevKr/rai/blob/main/docs/ios.md)):

- **Live terminal streaming** — panes stream to the phone as raw terminal frames
  (real scrollback, colors, no flicker), not flat screen snapshots.
- **Push notifications** — get an "agent needs you / finished" alert on your phone
  when an agent goes blocked or done. The always-on Mac talks to APNs directly
  (no relay server); configure it in **Settings → iPhone → Push** with your Apple
  Developer APNs key. (Real delivery needs a paid Apple Developer account + a
  signed device build.)
- **At-a-glance monitor** — spaces → tabs → agent status with a "Needs you" summary,
  a live SwiftTerm terminal per pane, input + compose bar, and auto-reconnect.

Turn on the bridge in **Settings → iPhone** (QR pairing over your LAN / Tailscale).

### Install

1. Download the `.dmg` below, open it, and drag **Rai** into **Applications**.
2. rai isn't notarized yet (no paid Apple Developer account), so on first launch
   macOS Gatekeeper will block it. Do **one** of:
   - **Right-click** `Rai.app` → **Open** → **Open**, or
   - run `xattr -dr com.apple.quarantine /Applications/Rai.app` and launch normally.
3. Make sure a herdr server is running (`herdr server`), then open rai.

Prefer to build it yourself? `git clone` and run `./scripts/bundle.sh`.
