Native macOS client for [herdr](https://herdr.dev). Universal binary (Apple Silicon + Intel), macOS 14+.

### New in this release

- **Fix: agents launched from your phone keep their pane** — a v0.1.10
  regression where an agent started from the iOS companion closed its pane (and
  a single-pane tab) on exit; it now drops back to a shell prompt like every
  other launch.
- **Agent panes outlive their agents** — exiting a coding agent no longer
  closes its pane (or the whole tab, when it was the only pane). The pane now
  drops back to a shell prompt instead, the same as exiting an agent you
  started by hand in a terminal.
- **Answer agents from your phone** — the iOS companion gains actionable
  blocked-agent notifications, native scrollback search, photo-to-pane
  transfer, and herd controls with a matching terminal theme.
- **Faithful phone terminal** — panes render at a fixed 80-column grid inside
  a horizontal scroll view, so wide agent output no longer reflows to
  phone width.
- **Bridge over Tailscale** — the companion bridge is exposed through
  `tailscale serve` and advertises a resolvable Bonjour hostname, so the
  phone can reach your herd away from home.

### Install

1. Download the `.dmg` below, open it, and drag **Rai** into **Applications**.
2. rai isn't notarized yet (no paid Apple Developer account), so on first launch
   macOS Gatekeeper will block it. Do **one** of:
   - **Right-click** `Rai.app` → **Open** → **Open**, or
   - run `xattr -dr com.apple.quarantine /Applications/Rai.app` and launch normally.
3. Make sure a herdr server is running (`herdr server`), then open rai.

Prefer to build it yourself? `git clone` and run `./scripts/bundle.sh`.
