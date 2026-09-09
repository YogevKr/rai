Rai now accepts APNs device tokens of variable length. This fixes registration failures with Apple's 80-byte simulator tokens.

The update preserves existing phone pairing. No new iOS build is required. Rai Remote build 40 remains available through TestFlight.

Validation confirmed actual Apple push delivery, the notification badge, and navigation to the correct pane in isolated apps.
The Mac suite completed 942 tests, with seven skips and no failures. Focused push checks passed 54 tests.

Silent retractions reached iOS, but automatic removal remains unverified. A direct debugger callback removed the test alert.
The live sender check bypassed Mac notification preference gates. Full Herdr-event-to-APNs preference coverage remains unverified.

Update through **Rai → Check for Updates…**, download the DMG, or run:

```sh
brew upgrade --cask yogevkr/tap/rai
```

See [v0.1.56](https://github.com/YogevKr/rai/releases/tag/v0.1.56) for the Herdr 0.9 features and other validation limits.
