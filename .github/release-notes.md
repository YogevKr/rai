Rai 0.1.69 keeps the SSH tunnel open when you switch to a local Herdr session.

- The remote session list stays available while you use a local session.
- Selecting the previous remote session reuses its SSH tunnel.
- Disconnect Remote closes the tunnel and keeps your active local session connected.
- Quitting Rai closes the tunnel.

Update through **Rai → Check for Updates…**, download the DMG, or run:

```sh
brew upgrade --cask yogevkr/tap/rai
```
