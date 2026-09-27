Rai 0.1.64 improves tab ordering, pane recovery, and terminal scrolling.

- Reopened tabs return to their saved position in the space.
- Use **Pane → Reopen Closed Pane** or **⌘⇧P** to restore a closed split pane.
- Reopened panes retain their working directory and resume agents when session data is available.
- Drop a tab below the final tab to keep it at the end of the same space.
- Terminal scrolling clears prediction overlays and keeps terminal text below pane headers.

Pane recovery creates a right split in the main window. It uses another tab in the space when needed.

Update through **Rai → Check for Updates…**, download the DMG, or run:

```sh
brew upgrade --cask yogevkr/tap/rai
```
