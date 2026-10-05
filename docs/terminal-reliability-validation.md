# Terminal reliability validation

Date: 2026-10-05.

The 0.1.78 candidate passed automated checks and isolated Mac and phone checks.
The application source is commit `cdeba7f8de1fe81ad85b21072c73ae85e21e87a1`, based on released version 0.1.77.
The final release removes the temporary lab workflow. It does not change application source.

## Automated checks

| Check | Result |
| --- | --- |
| Focused terminal tests | 25 tests passed. |
| Mac suite | 1,017 tests, nine skipped, zero failures. |
| iOS suite | 420 tests passed. |
| Build scripts | 16 tests passed. |
| Code review | No actionable findings. |
| Signed universal lab app | Developer ID signing, notarization, Gatekeeper, and ticket validation passed. |
| Native endpoint | Live handshake passed with Herdr 0.9.3. |

[The signed lab workflow](https://github.com/YogevKr/rai/actions/runs/37363806573) passed on attempt two.
Attempt one failed during runner assignment. No tests ran during that attempt.

Regression tests reproduce stale scroll state after overflow and cancellation failures during stalled reads.
A test with 15 stalled panes failed before the dedicated-thread change and passed afterward.

## Isolated app checks

The Mac displayed 1,000 output lines, scrolled through history, and returned to live output.
Drag selection produced a visible highlight. Resizing changed the viewport from 38 rows to 45 rows and back.
The Mac restored the test pane and its output after an app restart.

The phone paired with the isolated Mac and displayed the legacy Pane view.
It reconnected after the Mac restart and accepted a command that produced the expected output.
Landscape rotation and accessibility scrolling passed. Scrolling changed the displayed rows and returned to current output.

## Verification limits

Phone native Workspace View, touch scrolling, and text selection remain unverified on this candidate.
CUA coordinate targeting failed. Accessibility actions worked.
Mac selection persistence after scrolling away and back remains unverified.
Physical phone behavior remains unverified.

The installed Mac application remained unchanged.
Local evidence: `/private/tmp/rai09-6uxnzqv9/reliability-validation.json`.
