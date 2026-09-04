Native macOS client for [herdr](https://herdr.dev). Universal binary (Apple Silicon + Intel), macOS 14+.

### New in this release

- **⌘-click on a path opens the file instead of a Finder error.** SwiftTerm's
  Ghostty-style detector treats bare paths (`~/Downloads/report.html`,
  `./src/a.swift:12`) as links, and its default handler passed them to
  LaunchServices as scheme-less URLs. Every ⌘-click on a path, deliberate or a
  stray click with ⌘ still held after ⌘C, drew Finder's "The application can't
  be opened. -50". Rai now resolves the text first: `~` and `$VAR` expand,
  relative paths resolve against the pane's working directory, a trailing
  `:line:col` or stray punctuation is dropped, and only a path that exists
  opens, with its default app. URLs with a scheme still go to their handler.
  Anything unresolved beeps; nothing shows an alert.

Ships with **Rai Remote build 34** (TestFlight; build 33 froze on every pane open and is superseded): structured Claude prompt
controls (AskUserQuestion wizard, trust dialogs), Approve/Deny decisions,
transcript history for hook-enabled panes, a statusline strip, notification
preferences, and a password-prompt guard on every typed send.

Bridge protocol stays 6 (all additions are optional fields); existing
pairings keep working.

### Install

```sh
brew install --cask yogevkr/tap/rai
```

Or download the `.dmg` below, open it, and drag **Rai** into **Applications**.

Then open rai — it starts the herdr server itself if one is not running.

Prefer to build it yourself? `git clone` and run `./scripts/bundle.sh`.
