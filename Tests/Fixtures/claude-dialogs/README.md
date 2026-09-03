# Claude Code dialog fixtures

Grid reads of real Claude Code dialogs, taken with `herdr pane read --source
visible` from an isolated herdr lab (`scripts/herdr-lab.sh`) on 2026-09-03.
The `.txt` files are the text grid the phone's detector sees; the `.ansi`
twins keep the styling for renderer work.

| File | Claude | What |
| --- | --- | --- |
| `ask-user-question-q1.txt` | 2.1.259 | AskUserQuestion wizard, first (single-select) question, tab header `←  ☐ Color  ☐ Toppings  ✔ Submit  →` |
| `ask-user-question-q2-multiselect.txt` | 2.1.259 | Second question after Tab, multi-select checkboxes |
| `ask-user-question-submit.txt` | 2.1.259 | The Submit tab |
| `trust-dialog.txt` | 2.1.258 | Folder trust dialog: unnumbered rows, `❯` marks the selection, footer `Enter to confirm · Esc to cancel`. Transcribed from a live read, not byte-captured |

`codex-statusline.txt` holds a Codex 0.152.0 grid from the same isolated lab.
It includes the model, effort, and directory rows.

The numbered tool-permission dialog (`❯ 1. Yes … 4. No`, footer
`Esc to cancel · Tab to amend`) is inline in
`ios/rai-iosTests/PromptDetectionTests.swift`.
