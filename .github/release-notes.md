Native macOS client for [Herdr](https://herdr.dev). Universal binary for Apple Silicon and Intel. Requires macOS 14 or later.

### Full Disk Access guidance

- Rai now explains why commands such as 1Password CLI can trigger repeated macOS requests to access other apps’ data.
- The dialog appears once, including after upgrading. Choose **Open System Settings** or **Not Now**.
- The dialog shows Rai’s icon, follows light and dark appearance, and stays attached to the app window.
- Review the explanation again under **Settings → Herdr Server → Mac Privacy**.
- Rai opens the Full Disk Access settings page. You choose whether to grant access in macOS.

Full Disk Access is optional. It lets Rai and commands running through it access protected files, including other apps’ data.
If you enable it, quit and reopen Rai when macOS asks. Herdr keeps your agent sessions running.

The dialog does not grant access. Rai does not read protected files to test this permission.

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

Source builds require a stable signing identity. See [build instructions](https://github.com/YogevKr/rai/blob/v0.1.54/docs/TESTING.md).
