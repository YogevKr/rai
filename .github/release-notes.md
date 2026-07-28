Native macOS client for [herdr](https://herdr.dev). Universal binary (Apple Silicon + Intel), macOS 14+.

### New in this release

- **"Back to live" pill** — scrolling a pane (or a selection drag past the
  edge) used to leave it silently parked in scrollback, looking frozen. When a
  pane's viewport is off the live tail, a clickable pill now appears at its
  bottom-right and one click returns you to the tail (typing always did).
- **Tailscale pairing QR is back** — the bridge now finds the standalone
  `tailscale` CLI even without a shell PATH (the GUI app's binary can't run
  headless and made detection silently fail), and it retries instead of
  checking once at startup.
- **Push failures are visible** — if the APNs auth key goes missing while
  phones are registered, the bridge status says so instead of dropping pushes
  silently.

### Install

1. Download the `.dmg` below, open it, and drag **Rai** into **Applications**.
2. rai isn't notarized yet (no paid Apple Developer account), so on first launch
   macOS Gatekeeper will block it. Do **one** of:
   - **Right-click** `Rai.app` → **Open** → **Open**, or
   - run `xattr -dr com.apple.quarantine /Applications/Rai.app` and launch normally.
3. Make sure a herdr server is running (`herdr server`), then open rai.

Prefer to build it yourself? `git clone` and run `./scripts/bundle.sh`.
