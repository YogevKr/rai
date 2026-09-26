Rai 0.1.62 changes image paste to use temporary PNG files.

- Pasting a screenshot inserts its file path for a local agent to read.
- Dropping images inserts file paths without replacing the clipboard.
- Image paste no longer sends Ctrl-V to request a second clipboard read.

The image files stay on this Mac. Remote agents need files on their own host.

Update through **Rai → Check for Updates…**, download the DMG, or run:

```sh
brew upgrade --cask yogevkr/tap/rai
```
