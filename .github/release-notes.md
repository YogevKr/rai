Native macOS client for [herdr](https://herdr.dev). Universal binary (Apple Silicon + Intel), macOS 14+.

### New in this release

- **Select into scrollback** — drag a selection past the top or bottom edge of
  a terminal and hold: the pane scrolls, the selection keeps growing across
  pages, and ⌘C copies the whole thing. Selections are sticky (Ghostty‑style);
  prefer the herdr gesture instead? Settings → Terminal → **Copy on select**
  makes releasing the drag copy and clear. Either way a small
  "Copied to clipboard" toast confirms it. (Works on panes herdr can
  host‑scroll; agent panes that own the mouse still select the visible screen.)
- **Agents that are waiting no longer claim to be finished** — rai now detects
  the background shells and monitors a Claude Code session leaves running.
  Waiting agents wear a ⏳ badge with the session's own task descriptions in
  the tooltip (right‑click → *Show Background Work…* for the full
  definitions), and the false "Finished" notification a waiting agent used to
  fire — on Mac and iOS — is suppressed until the work actually completes.
- **Right‑click everywhere** — panes get a context menu (Copy/Paste, splits,
  zoom, close, new tab — with their shortcuts), and the sidebar gets
  context‑aware menus: New Tab / New Space on spaces, tabs, and empty space.
  Broadcast now lives in the tab menu instead of a row button.
- **Pane close button** — split panes show an ✕ (⌘⇧W) in their bar.
- **One sidebar look** — single‑tab spaces render exactly like multi‑tab
  spaces: header + tab row, same menus, same drag‑reorder, collapsible.
- **Typing stays where you're looking** — keystrokes and Codex Micro pad
  presses can no longer leak into the terminal behind Settings or the
  command palette.

### Install

1. Download the `.dmg` below, open it, and drag **Rai** into **Applications**.
2. rai isn't notarized yet (no paid Apple Developer account), so on first launch
   macOS Gatekeeper will block it. Do **one** of:
   - **Right-click** `Rai.app` → **Open** → **Open**, or
   - run `xattr -dr com.apple.quarantine /Applications/Rai.app` and launch normally.
3. Make sure a herdr server is running (`herdr server`), then open rai.

Prefer to build it yourself? `git clone` and run `./scripts/bundle.sh`.
