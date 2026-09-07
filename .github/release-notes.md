Native macOS client for [Herdr](https://herdr.dev). Universal binary for Apple Silicon and Intel. Requires macOS 14 or later.

### Agent startup prompts

Rai no longer reports **Could not launch claude** when Claude opens its folder-trust prompt.
The agent has started and needs your input. Complete the prompt in Rai or Rai Remote.

Rai checks the requested pane, agent, and blocked state before accepting a startup readiness error.
Actual launch failures still produce an error. Rai does not answer trust prompts or type another launch command.

This fix runs in the Mac app. Update Rai on your Mac; no new Rai Remote build is needed.

### Install

Use **Rai → Check for Updates…**, or install with Homebrew:

```sh
brew install --cask yogevkr/tap/rai
```

To update an existing Homebrew installation:

```sh
brew upgrade --cask yogevkr/tap/rai
```

You can also download the DMG below and drag **Rai** into **Applications**.
Users of version 0.1.49 should use the DMG or Homebrew because its in-app update can stall during shutdown.

Source builds require a stable signing identity. See [build instructions](https://github.com/YogevKr/rai/blob/v0.1.55/docs/TESTING.md).
