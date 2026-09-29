Rai 0.1.68 fixes alternate-screen scrolling on iPhone.

- Vertical swipes over a focused alternate-screen pane send wheel input while the bridge is busy.
- The Mac bridge forwards these wheel events while it processes another request.
- Update the Mac app and iPhone app to receive the complete fix.
- Codex still starts and resumes with `--no-alt-screen` for native terminal scrollback.

Update through **Rai → Check for Updates…**, download the DMG, or run:

```sh
brew upgrade --cask yogevkr/tap/rai
```
