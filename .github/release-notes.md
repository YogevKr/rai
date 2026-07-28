Native macOS client for [herdr](https://herdr.dev). Universal binary (Apple Silicon + Intel), macOS 14+.

### New in this release

- **Fixes heavy background CPU/disk use from v0.1.17's background‑work
  detection** — a cache that never matched live session transcripts meant rai
  re‑scanned megabytes of history every few seconds, felt as typing and
  scrolling lag (especially on loaded machines). Detection now caches
  properly: steady‑state cost is effectively zero, with the same ⏳ accuracy.

### Install

1. Download the `.dmg` below, open it, and drag **Rai** into **Applications**.
2. rai isn't notarized yet (no paid Apple Developer account), so on first launch
   macOS Gatekeeper will block it. Do **one** of:
   - **Right-click** `Rai.app` → **Open** → **Open**, or
   - run `xattr -dr com.apple.quarantine /Applications/Rai.app` and launch normally.
3. Make sure a herdr server is running (`herdr server`), then open rai.

Prefer to build it yourself? `git clone` and run `./scripts/bundle.sh`.
