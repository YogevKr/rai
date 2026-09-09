# Herdr 0.9 theme validation

Date: 2026-09-09.

## Current status

Both apps passed appearance, border, independent preference, and theme-save image checks.
Phone TOML import and title contrast also passed.
Both editors passed file import, preview cancellation, reset, and separate light/dark override editing.
Mac pasted import also passed.
Candidate46 confirmed saved theme values on both apps after restart.
Candidate46 also confirmed live Mac System appearance changes.

Current appearance evidence includes Candidate46.

## Remaining UI cases

No theme UI cases remain in this document.
The Mac endpoint followed Dark, Light, and Dark without restarting.
The check restored the original operating-system Dark mode and endpoint Light mode.
Artifacts: `theme46-persistence-checks.json` and `theme46-system-appearance.json` in the owned lab.

## Implementation and earlier evidence

The shared theme model imports 18 Herdr palettes and all 19 custom color tokens.
The catalog follows `herdr/src/app/state.rs`.
The importer follows `herdr/src/config/theme.rs` and the documented theme tables.

The importer supports single-line quoted values in these tables:

- `[theme]`
- `[theme.custom]`
- `[theme.custom.light]`
- `[theme.custom.dark]`

The importer accepts optional `[ui].pane_borders` values.
The existing border parser maps `true` to Always and `false` to Off.
The importer also accepts Always, Auto, and Off strings.

The importer rejects unknown theme settings, colors, and tokens.
It rejects duplicate settings, duplicate tables, multiline strings, inline tables, and files above 1 MB.
Errors identify the source line when applicable.
Other configuration tables do not change client settings.

The editor supports shared colors and separate light and dark colors.
It previews imports before Save.
Cancel leaves saved preferences unchanged.
Import does not write host configuration.

Native terminal defaults use text, panel background, selection background, and ANSI color overrides.
Herdr retains explicit RGB cell colors.
The shared palette retains other tokens for native presentation controls.
No code replaces terminal cell colors by matching RGB values.

Focused validation used copied source files outside the active worktree.
A reduced test host excluded unfinished changes from other lanes.
The Mac host used the production RGBAColor definition without unrelated SettingsStore dependencies.

- Mac: 12 tests passed, zero failures.
- iOS: 11 tests passed, zero failures.
- Log: `/tmp/rai09-theme-native-tests.log`.
- Log: `/tmp/rai09-theme-ios-tests.log`.
- Snapshot: `/private/tmp/rai09-theme-validation-source`.
- Simulator: `5990A3A3-B6DA-4B1C-B715-899C0E4F5AD8`, named Rai Theme Validation.
- Phone test bundle: `com.whetstone.rai.ios.lab.themes`.

Tests cover all catalog tokens, precedence, mode names, aliases, strict colors, errors, limits, persistence, and legacy borders.
Native tests verify color changes preserve terminal text and grid columns.

Later isolated UI checks found image loss after saving a theme.
A full ANSI repaint clears SwiftTerm image data even when the grid keeps its size.
Both renderers now reset their graphics cache after appearance changes.
Two Mac renderer tests passed, including three consecutive full repaints with image restoration.
Log: `/tmp/rai09-theme-graphics-tests.log`.

Native sidebar and pane lists now use palette background, active row, text, secondary text, and accent colors.
A reset sidebar background falls back to the palette panel background.
Explicit metadata rule colors keep precedence over palette defaults.
The iOS theme sheet now uses the root view presenter outside the transient Actions menu.
The complete copied Mac app compiled after these changes.
Both renderer tests passed again in `/tmp/rai09-theme-chrome-tests.log`.
Candidate39 confirmed Mac image preservation and phone theme sheet presentation.
Candidate42 confirmed phone image preservation after an accent change.

The first native builds found an ambiguous SwiftUI.Color reference.
The corrected source passed both native test hosts.
Candidate43 passed the combined gates with 876 Mac tests, six skips, 371 iOS tests, and three live SSH tests.
The gates reported zero failures.
Evidence: `/private/tmp/rai09-391wxjtr/candidate43-checks.json`.

## Isolated UI evidence

The lab uses `/private/tmp/rai09-391wxjtr`.
`appearance29-checks.json` records Light, Dark, and System modes on both apps.
It also records phone system appearance changes in both directions.
Always, Auto, and Off borders passed on both apps without changing pane text.
`window34-checks.json` confirms separate Mac window appearance and border choices.
`window35-checks.json` confirms new-window defaults and preference persistence after restart.
Existing windows retained their independent choices.

`candidate39-checks.json` records phone TOML import with Dracula and a custom accent.
The integrated validation notes record independent Mac cyan and phone green accents.
Mac theme changes preserved images.
`candidate42-checks.json` records phone image preservation after saving a magenta accent.
`candidate43-checks.json` confirms the phone Panes title remains readable under Dracula.

Final parser cleanup separated table validation and rejected malformed headers.
All ten parser tests passed again in `/tmp/rai09-theme-parser-final-tests.log`.

## Completed editor UI checks

Mac Candidate43 and phone Candidate44 completed these checks through isolated native app interfaces.
Evidence: `/private/tmp/rai09-391wxjtr/theme43-trust-stop-checks.json`.

Both file pickers imported the owned `theme43-import.toml` file.
The import selected Dracula, separate Latte/Dracula modes, and distinct shared/light/dark accent values.
Both editors showed an imported preview before Save.
Cancel preserved the previously saved base theme and override settings.

Mac pasted import populated the same theme and override values.
Both editors accepted separate light and dark accent edits without changing the other layer.
Reset changed the base to Rai Default, selected automatic mode palettes, and cleared the overrides.
Phone Save then retained the reset base and newly entered mode accents.
Mac Save retained the imported theme and its original mode accents.

| Saved setting | Mac | Phone |
| --- | --- | --- |
| Base theme | `dracula` | Empty name: Rai Default |
| Separate colors | `true` | `true` |
| Light theme | `catppuccin-latte` | Empty name: Automatic |
| Dark theme | `dracula` | Empty name: Automatic |
| Shared accent | `#ff00ff` | No override |
| Light accent | `#0066ff` | `#2255ee` |
| Dark accent | `#00ff88` | `#22ee88` |
| Appearance | `light` | `system` |
| Pane borders | `always` | `auto` |

Exact stored strings appear in `theme43-mac-saved-preferences.json` and `theme43-phone-saved-preferences.json` in the lab root.
These reads confirmed persistence to preferences before the next app restart.
