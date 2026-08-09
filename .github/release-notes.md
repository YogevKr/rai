Native macOS client for [herdr](https://herdr.dev). Universal binary (Apple Silicon + Intel), macOS 14+.

### New in this release

- **Rai no longer freezes during sidebar updates.** Rai now avoids a SwiftUI
  lazy-layout loop. It also combines focus refreshes and skips equal snapshots.
- **Large herds no longer churn terminal clients.** The terminal pool now
  follows the live herd size. It also removes stale clients before resize.
- **Repeated close actions are safe.** Rai ignores held ⌘W shortcuts and
  duplicate close clicks. A close also stays bound to its source herd.

### Install

```sh
brew install --cask yogevkr/tap/rai
```

Or download the `.dmg` below, open it, and drag **Rai** into **Applications**.

Then open rai — it starts the herdr server itself if one is not running.

Prefer to build it yourself? `git clone` and run `./scripts/bundle.sh`.
