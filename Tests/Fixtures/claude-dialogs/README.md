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
| `ask-user-question-single-select.txt` | 2.1.259 | One single-select question, one `☐ Color` header chip, and arrow-only navigation help |
| `ask-user-question-single-multiselect.txt` | 2.1.259 | One multi-select question, `←  ☐ Checks  ✔ Submit  →`, and arrow-only navigation help |
| `trust-dialog.txt` | 2.1.258 | Folder trust dialog: unnumbered rows, `❯` marks the selection, footer `Enter to confirm · Esc to cancel`. Transcribed from a live read, not byte-captured |
| `trust-dialog-wrapped.txt` | synthetic | Trust shape with one wrapped option label for parser regression coverage |
| `quoted-trust-dialog.txt` | synthetic | Inert quoted trust text above Claude's live composer and status line |
| `quoted-ask-user-question.txt` | synthetic | Inert quoted AskUserQuestion text above Claude's live composer and status line |

`codex-statusline.txt` holds a Codex 0.152.0 grid from the same isolated lab.
It includes the model, effort, and directory rows.
`codex-statusline-negative.txt` holds transcript and output shapes that must not
become a status strip.

The numbered tool-permission dialog (`❯ 1. Yes … 4. No`, footer
`Esc to cancel · Tab to amend`) is inline in
`ios/rai-iosTests/PromptDetectionTests.swift`.
