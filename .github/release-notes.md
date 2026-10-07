Rai 0.1.90 keeps remote closure usable during reconnects.

- A successful remote close disappears from Rai before the next metadata snapshot arrives.
- Rai captures the newest remote connection identity before closing a tab.
- SSH URI and plain target forms use one remote sidebar identity.
- Duplicate source rows use one canonical connection, so close actions reach the live instance.
- Closing the last remote tab closes its source workspace because Herdr rejects last-tab closure.
- Remote New Space stays guarded until the new space appears in endpoint metadata.

Rai 0.1.89 prevents duplicate space creation.

- Repeated New Space clicks create one space per request.
- Direct and saved remote connections use one sidebar identity.
- Multiple real spaces on one instance remain visible.

Rai 0.1.88 removes duplicate remote spaces.

- Rai shows one row when a direct remote connection and its saved machine mirror describe the same space.
- Multiple spaces remain visible for one remote instance.
- Command-W closes the selected remote source tab from the normal Rai window.

Rai 0.1.86 adds source closure to remote tab menus.

- Right-click a remote tab and choose Close Tab to close it in Herdr.
- Remove from Rai view remains available when the source must keep running.

Rai 0.1.85 closes remote tabs at their source.

- Command-W and Tab → Close Tab close the selected tab in its Herdr instance.
- Closing the source tab stops its processes. Other tabs remain open.
- Closing the actual last tab also closes its source space.
- Remove from Rai view keeps the source tab and its processes running.
- Failed source closure keeps the tab visible and shows an error.

Rai 0.1.83 fixes local and remote tab titles.

- Codex tabs show `codex` when their only title is a session UUID.
- Useful terminal titles replace that fallback when available.
- Custom tab names remain unchanged.
- Remote titles update while another instance stays selected.
- Local tab names update after a rename, without waiting for terminal output.
- This release includes the command palette arrow fix from 0.1.82.

Rai 0.1.82 fixes command palette arrow navigation.

- Up and down arrows select palette rows on keyboards that send function-key characters.
- Arrow characters no longer enter the search query as replacement boxes.

Rai 0.1.81 keeps remote spaces view-only from Rai.

- Mixed remote panes no longer show a second terminal header.
- Removing a remote space or tab removes it from Rai only.
- Herdr keeps the remote workspace, tab, and running processes alive.

Rai 0.1.80 keeps remote Herdr Codex sessions running when Rai connects.

- Remote Rai terminal views never request terminal takeover.
- Rai keeps takeover for local terminal views.
- Remote and local attachment paths restore the correct mode when switching instances.

Rai 0.1.79 makes remote spaces match local spaces in the sidebar.

- Remote spaces use the same collapse, status, tab, and close controls as local spaces.
- Remote tabs show useful labels and working-directory context.
- Rai keeps multiple spaces from each instance visible in one workspace.

Rai 0.1.78 improves terminal recovery.

- Rai rejects invalid terminal updates before they change the displayed surface.
- Event buffers have fixed limits. Rai reconnects and reads current state after an overflow.
- Scroll selection and the return-to-live indicator recover when scrolling stops during an overflow.
- Metal rendering remains optional. The default renderer does not change.

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
