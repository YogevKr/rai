Native macOS client for [herdr](https://herdr.dev). Universal binary (Apple Silicon + Intel), macOS 14+.

### New in this release

- **Branch shown per tab, not per space.** Each tab row now carries the Git
  branch and ahead/behind counts of its own shell directory, so tabs that sit
  in different worktrees of one space each show their own branch. The space
  header no longer shows a branch; a linked worktree or a renamed space keeps
  its checkout name there.

No Rai Remote change in this release. The current TestFlight build (35) keeps
working, and the bridge protocol stays 6.

### Install

```sh
brew install --cask yogevkr/tap/rai
```

Or download the `.dmg` below, open it, and drag **Rai** into **Applications**.

Then open rai — it starts the herdr server itself if one is not running.

Prefer to build it yourself? `git clone` and run `./scripts/bundle.sh`.
