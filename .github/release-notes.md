Native macOS client for [herdr](https://herdr.dev). Universal binary (Apple Silicon + Intel), macOS 14+.

### Fixed in this release

Splitting and closing panes now leave every pane drawn where it belongs.

- **Splitting a pane no longer blanks the pane you split from.** The pane kept
  its terminal and its scrollback, but the view dropped out of the window, so
  it stayed empty until you switched tabs and came back.
- **Closing one of two panes redraws the survivor at full size.** It used to go
  blank, or keep drawing at its old half width in a full-width pane.
- **Zoom (⌘⇧↩) now actually zooms.** A zoomed pane fills its tab instead of
  only gaining a "Zoomed" badge while the split stayed put.
- **Closing a pane no longer spawns a stray `herdr terminal attach`** for the
  terminal that just went away.

### Install

```sh
brew install --cask yogevkr/tap/rai
```

Or download the `.dmg` below, open it, and drag **Rai** into **Applications**.

Then make sure a herdr server is running (`herdr server`), and open rai.

Prefer to build it yourself? `git clone` and run `./scripts/bundle.sh`.
