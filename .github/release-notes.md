Rai 0.1.77 keeps update checks working when GitHub API limits apply.

- Rai reads the public release feed when the GitHub API is unavailable.
- Release manifests keep archive size and SHA-256 checks.
- Mixed Rai panes hide generated pane labels.

Rai 0.1.73 adds safe closure for remote spaces and tabs.

- Right-click a remote tab to close it from the Rai sidebar.
- Right-click a remote space to review and close the whole space.
- Rai validates the remote Herdr instance, workspace, tabs, and panes before closure.
- A one-tab space always asks for confirmation before closure.

Rai 0.1.72 fixes the mixed remote view layout.

- Mixed remote panes now use the full detail area.
- The view no longer leaves blank space beside the pane grid.

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
