Native macOS client for [Herdr](https://herdr.dev). Universal binary for Apple Silicon and Intel. Requires macOS 14 or later.

Validation and known limits appear below.

### Herdr 0.9 on Mac and iPhone

Rai 0.1.56 adds Herdr 0.9 controls on macOS and through Rai Remote on iOS.
The matching phone update is **Rai Remote 1.0, build 40**. These phone features require that update.

- Open independent workspace views across Mac windows and connected phones.
- Manage local machines, saved SSH connections, and named sessions. Search agents across machines.
- Create, rename, move, split, resize, and close workspace resources. Review affected workspaces before closing a group.
- List, create, open, and remove worktrees. Grant repository trust for one request.
- Configure sidebar metadata rules, light and dark themes, palette overrides, and pane borders.
- Render terminal images and inspect captured images. Use plugin commands, links, popups, notifications, and filtered agent views.
- Inspect retained terminal history and submit composed prompts through Herdr's atomic prompt operation.
- Use semantic keyboard input, mouse input, and multiline paste. Popup input stays within its popup.
- Read agent status explanations, command lists, and news. Manage client updates and supported server handoffs from either platform.

Phone connections continue through the paired Mac. Supported native views keep navigation independent across clients.
Updating a compatible client preserves running agents. Server replacement remains a separate action.
Older Herdr servers retain supported operations, including ordinary workspace closure.

### Startup, scrolling, and text

A new Mac without Herdr now reaches installation guidance instead of a stalled startup screen.
File-access guidance appears when an operation needs access. Installing Herdr alone does not trigger permission guidance.

Pane scrollbars appear during scrolling and fade afterward. Translucent overlays preserve terminal layout and rendering dimensions.

Both iOS terminal views support captured text selection and web links.
Selection preserves the captured text while terminal output continues.

### Connection safety and recovery

Workspace closure checks the reviewed resources before sending a request. Changed connections and unsafe group closures require another review.
Remote operations retain their selected machine and connection. Failed mutation requests do not reconnect and replay on another server.

Phone views recover after host reconnect and app suspension. Recovery clears queued input and creates a new view identity.
Closing a phone view keeps it closed.

### Known limits and validation

Herdr can send another client's workspace title after a Mac window resize.
The selected pane and terminal content remain correct in the reproduced case.
Herdr also shares history position between views of the same pane.
Popups belong to tabs. Clients selecting the same tab share popup presentation.
Current upstream popup mouse input can fall back to cells. Its graphics API cannot activate the required popup pixel layer.

Candidate63 passed 938 Mac tests and 407 iOS tests, with seven Mac skips and no failures.
Integrated Codex review found no defects. Earlier Candidate61 Mac timing-test failures remain in the validation record.

Popup browser links and native selection controls passed executable app checks, subject to the limits below.
Native metadata accessibility labels expose status names on both platforms. Actual VoiceOver speech remains unmeasured.
Popup links support HTTP(S). Custom schemes and wrapped plain popup URLs remain unsupported; wrapped explicit OSC8 links use their targets.
Mac pixel press, drag, release, and resize checks passed. Independent history, menus, and popup text/input checks also passed.
Lazy access-help checks also passed. Upstream lacks native plugin-pane launch capability; controls must report its unavailability.
Configured popup commands provide the supported native fixture route. Initial app checks confirmed tab sharing and cell-coordinate fallback.
Phone composition passed exact byte checks. Phone popup web links and custom-scheme rejection also passed.
Phone pixel taps passed with distinct positions within one cell and matching press/release packets.
Both platforms passed long input bursts, accent composition, and literal History search on Candidate63.
Both paired phones retained their connections after the update.
Selection motions passed on both platforms. Both apps retained all 400 history rows.
Historical/current memory observations establish no memory savings because presentation and geometry differed.
Unmatched explicit links passed through Mac Links and direct phone tap. Mac Command-click remains unverified.
Phone metadata forms passed largest-size reachability checks. Popup mouse, keyboard, phone tap, and Return checks passed with cell fallback.
Phone drag injection produced no packets. Sound output remains unmeasured because exact-app capture lacks reliable playback attribution.
Physical input and APNs claims require separate device evidence. Muse is excluded from this release scope.

See the [validation checkpoint](https://github.com/YogevKr/rai/blob/v0.1.56/docs/herdr-09-integrated-validation.md) for evidence and remaining limits.

### Install

Use **Rai → Check for Updates…**, or install with Homebrew:

```sh
brew install --cask yogevkr/tap/rai
```

To update an existing Homebrew installation:

```sh
brew upgrade --cask yogevkr/tap/rai
```

You can also download the DMG below and drag **Rai** into **Applications**.
Users of version 0.1.49 should use the DMG or Homebrew. Its in-app update can stall during shutdown.

Update Rai Remote through TestFlight when build 40 becomes available. External access requires Apple's beta review approval.
Existing build 39 reports external `IN_BETA_TESTING`. This status does not establish availability of the planned build 40.

Source builds require a stable signing identity.
See [build instructions](https://github.com/YogevKr/rai/blob/v0.1.56/docs/TESTING.md).
