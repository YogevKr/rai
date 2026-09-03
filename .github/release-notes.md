Native macOS client for [herdr](https://herdr.dev). Universal binary (Apple Silicon + Intel), macOS 14+.

### Fixed in this release

- **Pushes work again with a pasted or migrated APNs key.** The Mac now loads
  the `.p8` from its DER whatever shape it was stored in (CRLF line ends,
  one line, quotes, body only, or a hex-encoded PEM), never caches a failed
  Keychain read, and the test push and Doctor say why a key cannot be used
  instead of an ASN.1 error. A dead device token (410) is pruned on the spot.
- **Pairing a fresh phone no longer fails with "Pair Again".** Fixed on the
  phone in Rai Remote build 32; this release carries the harness affordance
  (`RAI_PAIRING_CODE_FILE`) and the start-time publish of the pairing code.

Ships with **Rai Remote build 32** (TestFlight). Both sides use bridge
protocol 6: existing phones pair again with the code from Settings → iPhone.

### Install

```sh
brew install --cask yogevkr/tap/rai
```

Or download the `.dmg` below, open it, and drag **Rai** into **Applications**.

Then open rai — it starts the herdr server itself if one is not running.

Prefer to build it yourself? `git clone` and run `./scripts/bundle.sh`.
