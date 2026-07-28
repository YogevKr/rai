Native macOS client for [herdr](https://herdr.dev). Universal binary (Apple Silicon + Intel), macOS 14+.

### New in this release

- **Waiting agents now count subagents and workflows** — background‑work
  detection (the ⏳ badge, hover summaries, *Show Background Work…*, and the
  false‑"Finished" suppression) now also sees in‑flight **subagents** and
  **workflows**, recovered from the session transcript with the session's own
  descriptions — e.g. *[subagent] Map case‑closure lifecycle paths* — alongside
  the process‑backed background shells and monitors.

### Install

1. Download the `.dmg` below, open it, and drag **Rai** into **Applications**.
2. rai isn't notarized yet (no paid Apple Developer account), so on first launch
   macOS Gatekeeper will block it. Do **one** of:
   - **Right-click** `Rai.app` → **Open** → **Open**, or
   - run `xattr -dr com.apple.quarantine /Applications/Rai.app` and launch normally.
3. Make sure a herdr server is running (`herdr server`), then open rai.

Prefer to build it yourself? `git clone` and run `./scripts/bundle.sh`.
