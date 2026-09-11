Rai 0.1.59 removes a delay when Rai Remote opens a terminal session.

- The Mac starts the live stream without waiting for an unused preview.
- Rai Remote starts the live stream before it requests terminal history.
- Rai Remote loads its saved workspace snapshot outside the main UI thread.
- Older phone clients keep the existing preview fallback.

Use Rai Remote 1.0 build 41 with this Mac release to receive all changes.
The regression test verifies that stream attachment starts before the history request.
Physical-device startup timing remains unmeasured.

Update through **Rai → Check for Updates…**, download the DMG, or run:

```sh
brew upgrade --cask yogevkr/tap/rai
```
