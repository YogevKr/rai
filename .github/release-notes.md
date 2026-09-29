Rai 0.1.66 improves pane focus, Codex scrolling, CI stability, and the README.

- Rai follows a pane focus change made by another Herdr client.
- Rai starts and resumes Codex with `--no-alt-screen`, preserving scrollback across messages on Mac and iPhone.
- Existing Codex sessions need a restart with `codex --no-alt-screen resume` to enable terminal scrollback.
- The CI timeout matches the request timeout on slower runners.
- The README now gives the install and feature paths in one short page.

Update through **Rai → Check for Updates…**, download the DMG, or run:

```sh
brew upgrade --cask yogevkr/tap/rai
```
