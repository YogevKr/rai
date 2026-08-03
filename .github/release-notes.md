Native macOS client for [herdr](https://herdr.dev). Universal binary (Apple Silicon + Intel), macOS 14+.

### New in this release

- **Typing to a remote herd no longer waits for the network.** rai now
  predicts your keystrokes mosh-style: printable characters appear instantly,
  underlined until the server confirms them, then blend in. Prediction only
  engages once the link has proven slow, never inside full-screen TUIs, and
  never at hidden-input prompts — a password can't be painted on screen,
  because rai only predicts while the prompt is demonstrably echoing.
- **Remote sessions in the session menu.** While connected to a remote
  target, the menu lists that machine's sessions next to your local ones;
  pick one to switch without retyping the SSH target.

### Install

```sh
brew install --cask yogevkr/tap/rai
```

Or download the `.dmg` below, open it, and drag **Rai** into **Applications**.

Then open rai — it starts the herdr server itself if one is not running.

Prefer to build it yourself? `git clone` and run `./scripts/bundle.sh`.
