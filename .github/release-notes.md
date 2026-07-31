Native macOS client for [herdr](https://herdr.dev). Universal binary (Apple Silicon + Intel), macOS 14+.

### New in this release

The sidebar gained an **agents panel** — every agent in the herd, flat, ordered
by who needs you (blocked, then finished, then working), with the herd's own
order as the alternative. It collapses to a count, and the divider between it
and the spaces list drags; all of it persists.

- **Jump to an agent by number** — ⌘⌥1–9 selects the Nth row *as displayed*, in
  either sort order.
- **Spaces show their branch** and how far it is ahead of / behind its upstream.
- **Worktrees group under their repo.** Every space sharing a checkout collapses
  under one parent, each child named for its branch.
- **Copy mode (⇧⌘C)** — move with `h/j/k/l`, `w/b/e`, `{`/`}`, select with `v`,
  yank with `y`, search with `/`, leave with Esc. While it is on, keys go to the
  mode, not the pty.
- **Edit Scrollback (⇧⌘E)** opens the pane's buffer in your editor.
- **Fix a misdetected agent** from the pane menu: set what is running in a pane,
  clear the override, or release rai's claim — with herdr's current detection
  shown so you can see what you are correcting.
- **Settings** gained plugin install / link / uninstall, the update channel,
  agent-detection manifests, herdr's release notes, and a live handoff that
  moves the server without stopping your agents.

### Fixed in this release

- **Coming back to an agent on the phone no longer shows stale rows above the
  live screen.** An agent on the alt screen has no scrollback, so the seed the
  phone asks for comes back empty — and an empty seed was dropped before it
  could reset the buffer, leaving the previous visit's rows in place.

### Install

```sh
brew install --cask yogevkr/tap/rai
```

Or download the `.dmg` below, open it, and drag **Rai** into **Applications**.

Then open rai — it starts the herdr server itself if one is not running.

Prefer to build it yourself? `git clone` and run `./scripts/bundle.sh`.
