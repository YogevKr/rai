# Claude transcript fixture

`claude-2.1.259.jsonl` came from a real Claude Code 2.1.259 session.

The session ran in the isolated herdr lab on 2026-09-03.
It contains two prompts and one Bash call.

The fixture removes account, organization, remote session, usage, and attachment data.
It keeps the real message shapes, identifiers, timestamps, and fixture-only path.
The final line is incomplete on purpose.

The capture also had mode, permission, attachment, title, system, snapshot, prompt, and cost records.
The parser skips these records and all unknown record types.
