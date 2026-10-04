Rai 0.1.71 removes the separate endpoint window and keeps machine setup in Rai.

- File → New Window no longer opens a second endpoint view.
- Machines… opens from the normal Rai session menu.
- Machine setup and remote instance support remain available.

Rai 0.1.70 added mixed Rai spaces, remote instance support, and faster switching.

- A Rai space can include spaces from several local or remote Herdr instances.
- Rai keeps multiple spaces per instance and shows each space's instance.
- Remote spaces use the existing Herdr management path and SSH transport.
- Sidebar redraws and space switching avoid repeated remote workspace scans.
- Terminal ownership and scroll tasks now stop cleanly during endpoint changes.

- Rai follows a pane focus change made by another Herdr client.
- Rai starts and resumes Codex with `--no-alt-screen`, preserving scrollback across messages on Mac and iPhone.
- Existing Codex sessions need a restart with `codex --no-alt-screen resume` to enable terminal scrollback.
- The CI timeout matches the request timeout on slower runners.
- The README now gives the install and feature paths in one short page.

Update through **Rai → Check for Updates…**, download the DMG, or run:

```sh
brew upgrade --cask yogevkr/tap/rai
```
