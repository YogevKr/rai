# Metadata layouts and rules

## Current validation status

Both platforms passed token addition, ordering, removal, invalid-color save rejection, numeric rules, and saved output.
Both platforms passed competing-rule precedence, explicit bold and dim removal, and a Codex layout override.
Mac red output and phone magenta output established separate client settings.
Mac reset cancellation preserved its earlier saved rule.

Candidate46 passed typed identifier checks and saved the phone configuration through the editor.
The saved settings survived restart. Candidate48 phone preferences exactly matched the saved Candidate46 rules and Codex override.

The Mac sidebar splitter stayed at 248. Phone terminal text retained its line breaks after the editor closed.
These observations establish the measured geometry checks; they do not replace broader terminal layout tests.

## Implementation

The native Workspace view now supports local metadata layouts on macOS and iOS.

The Metadata sheet edits workspace rows and agent rows. Agent overrides replace the complete default layout.

Each row supports token order, removal, and addition. Each token supports color, bold, dim, and ordered conditional rules.

The editor includes live snapshot previews and sample token previews. Save validates the complete configuration before storing it.

Cancel leaves saved settings unchanged. Restore Default Layouts changes the draft until Save.

These settings apply to this app. They do not change the host's Herdr configuration file.

## Contract

The implementation follows these upstream files:

- `herdr/src/config/sidebar.rs`
- `herdr/src/config/sidebar/rules.rs`
- `herdr/src/ui/sidebar/tokens.rs`
- `herdr/src/client/shell/agent_sidebar.rs`
- `herdr/src/protocol/wire.rs`

The model supports every workspace token and agent token, including custom `$name` tokens.

Rules use exact byte comparisons or ASCII letter folding. They evaluate full values before native text truncation.

The first matching rule stops evaluation. Explicit false values remove inherited bold or dim values.

Numeric rules require complete, finite decimal values. Spaces, units, hexadecimal values, NaN, and infinity do not match.

Layouts allow 16 rows, 16 tokens per row, and 16 rules per token.

State icons and Git status reject conditional rules. Colors require `#RGB` or `#RRGGBB`.

Absent values and empty rows disappear. Native views use the documented token separators.

The snapshot resolver preserves custom-token namespaces, display labels, state labels, and both terminal title variants.

Machine labels remain absent unless the caller supplies a verified machine label.

## Verification

Validation used a temporary source copy. Other agents could continue editing the shared worktree.

Temporary package:

`/var/folders/dj/7c4nlr0s6256kkqpqpk0r3pm0000gn/T/rai-metadata-validation-7ep31vfq`

The package contains copied RaiCore sources, the metadata views, and metadata tests.

macOS command:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --jobs 4
```

Result: 12 tests passed. The native metadata views compiled with the test package.

Log: `/tmp/rai-metadata-validation-tests.log`

The tests cover limits, invalid data, ordering, empty values, overrides, token meanings, styles, numeric matching, and saved settings.

A regression test exposed Swift's empty substring behavior. Byte matching now preserves Herdr's empty-condition and Unicode semantics.

iOS simulator SDK command:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift build --target MetadataViews --triple arm64-apple-ios17.0-simulator \
--sdk /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk \
--scratch-path .build-ios --jobs 4
```

Result: the shared metadata views and RaiCore compiled successfully.

Log: `/tmp/rai-metadata-validation-ios.log`

`git diff --check` passed.

The branch quality gate remains open. Its report includes other parallel changes.

The metadata files have new-symbol size and duplication findings. Their listed gating findings were removed.

The remaining metadata findings include type sizes, test bodies, and the small settings encoder shared with theme settings.

Log: `/tmp/rai-metadata-quality.log`

## Recorded UI evidence

Candidate39 CUA created an Equals rule for workspace name `Commands Lab` on both platforms.
The Mac preview and saved sidebar used red. The phone preview and saved pane list used blue.
These settings confirmed separate client preferences.
The Mac canceled a default-layout reset. Its saved rule remained active.
Candidate39 includes grouped Mac forms that corrected clipped editor labels.

Source: [Integrated validation](herdr-09-integrated-validation.md), Metadata section.
The metadata view, models, resolver, and tests have identical Candidate39 and Candidate43 source hashes.
This comparison does not replace a final app validation pass.

## Candidate43 source audit

The Candidate43 manifest matches all 196 current implementation files under `Sources` and `ios/rai-ios`.
No changed, missing, or new implementation files were found during this audit.
Manifest: `/private/tmp/rai09-391wxjtr/candidate43-source-manifest.json`.
Audit: `/tmp/rai-candidate43-source-audit.json`.


## Candidate43 Mac and Candidate44 phone editor completion

Both editors added `$score43`, moved it before `workspace`, and removed `state_icon`.
The isolated workspace supplied `score43=15`. Other workspaces omitted this token without leaving an empty value.
Both rejected Save with `#xyz` and displayed `Color must use #RGB or #RRGGBB.`.
Mac preferences remained unchanged after rejection. The phone rejection kept its draft open.
Both saved after correction and displayed `15 · Commands Lab`.

Mac used a green, bold, dim base style with two matching numeric rules.
The first `gt: 10` rule produced red text and explicitly removed bold and dim.
Moving `lt: 20` first produced blue text with inherited bold and dim.
The editor restored `gt: 10` first before Save.
Mac also saved a complete Codex override with a yellow agent label. Other agent defaults remained unchanged.

Phone used a green base and a blue `gt: 10` rule.
The iOS Edit controls moved the token by drag and removed the state icon through Delete.
Its saved pane list displayed blue numeric and workspace labels.
The phone editor did not yet test competing-rule order or explicit style removal.

Mac saved settings: `/tmp/rai-metadata43-mac-saved.json`.
Phone saved settings: `/tmp/rai-metadata44-phone-saved.json`.
UI observations: `/tmp/rai-metadata-plugin44-ui-evidence.json`.
The parent verified restart persistence after installing Candidate46, as recorded below.


## Candidate46 restart verification

Candidate46 passed 877 Mac tests, including six skips, and 374 iOS tests. Both suites reported zero failures.
After installation, the parent verified red Mac score output, yellow Codex labels, and blue phone score output.
The Mac sidebar splitter remained at 248.
These results confirm that both apps retained their saved metadata settings across restart.
Evidence: `candidate46_restart` in `/tmp/rai-metadata-plugin44-ui-evidence.json`.

## Candidate46 phone completion

The phone set `$score43` to green with Bold On and Dim On.
Its first rule used `gt:10` and blue. Its second rule used `lt:20` and magenta.
The second rule explicitly disabled Bold and Dim.
Sample `15` first appeared faded and bold blue.
Edit and drag moved the second rule first. Sample `15` changed to normal magenta.
This check established competing-rule precedence and explicit removal of inherited styles.

The Codex override changed Row 2's agent token to magenta.
After Save, Panes displayed magenta `15`, blue `Commands Lab`, and two magenta Codex labels.
Saved preferences contained both ordered rules and the Codex override.
Evidence: `/tmp/rai-metadata46-phone-saved.json` and `candidate46_completion` in `/tmp/rai-metadata-plugin44-ui-evidence.json`.

## Large text inspection

The themes agent inspected Metadata, Row Tokens, and Token controls at standard XXXL text size.
Labels, previews, token controls, and rule rows remained readable. The agent restored the original Large text size.
No metadata edits were saved.
This inspection does not cover accessibility text sizes, VoiceOver, or every rule editor screen.
Evidence: `/private/tmp/rai09-391wxjtr/notify47-ui-results.json`.
