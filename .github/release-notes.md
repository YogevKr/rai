Native macOS client for [Herdr](https://herdr.dev). Universal binary for Apple Silicon and Intel. Requires macOS 14 or later.

### Codex Micro fixes

- Rai reports device access failures at startup and after reconnection.
- Permission failures include an **Open Input Monitoring** button and recovery instructions.
- **Retry connection** restarts device monitoring and preserves your saved key bindings.
- Key binding changes now save the latest value and survive app restarts.

### Build identity

- Development builds install as **Rai Dev.app**, with a separate bundle ID and preferences.
- Development builds cannot replace Rai through release updates.
- Release builds require Developer ID signing and verify the expected publisher before installation.
- Missing signing certificates stop the build. Rai no longer substitutes ad-hoc signing.

If a development build previously replaced Rai, repair its existing Input Monitoring permission once.
Remove the old Rai entry in **System Settings → Privacy & Security → Input Monitoring**.
Add the installed **Rai.app**, enable it, then quit and reopen Rai.

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

Source builds require a stable signing identity. See [build instructions](https://github.com/YogevKr/rai/blob/v0.1.53/docs/TESTING.md).
