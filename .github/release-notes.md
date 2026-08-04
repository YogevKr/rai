Native macOS client for [herdr](https://herdr.dev). Universal binary (Apple Silicon + Intel), macOS 14+.

### New in this release

- **Reopen Closed Tab works again on herdr 0.7.5+.** herdr dropped `agent
  start --tab`; ⌘⇧T briefly showed the reopened tab and then closed it.
  Launching an agent from the UI or the phone companion silently did
  nothing. Both paths now use herdr's current commands, verify the agent
  actually started, and retry once if it did not.
- **Reopening a closed tab brings its space back.** Closing a space's last
  tab closes the space itself. ⌘⇧T now recreates that space — same name,
  same directory — instead of dropping the tab into whichever space was
  focused. Reopening several tabs from one closed space rejoins them in a
  single recreated space.
- **Space order stays in sync on herdr 0.8.0.** Reordering spaces
  (protocol 19's focus-neutral `workspace.move_block`) updates the sidebar
  immediately; older servers keep the baseline subscription set.

### Install

```sh
brew install --cask yogevkr/tap/rai
```

Or download the `.dmg` below, open it, and drag **Rai** into **Applications**.

Then open rai — it starts the herdr server itself if one is not running.

Prefer to build it yourself? `git clone` and run `./scripts/bundle.sh`.
