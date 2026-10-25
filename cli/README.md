# irudd-voice CLI

Reads the database the irudd-voice app writes
(`~/Library/Application Support/irudd-voice/voice.sqlite`).

```sh
cd cli
uv run irudd-voice stats          # or: uv run irudd-voice stats --json
uv run pytest                      # tests
```

The app owns the schema. The CLI never creates or migrates tables, and it
refuses to write to a database whose schema version it doesn't know.

## Labels, vocabulary and datasets

```sh
uv run irudd-voice vocab [--out PATH] [--dry-run]
uv run irudd-voice label [--teacher claude|codex] [--model M] [--limit N] [--db PATH] [--dry-run]
uv run irudd-voice dataset build [--db PATH] [--out DIR] [--augment-typed]
```

**`vocab`** reads what you typed into Claude Code
(`~/.claude/projects`), Codex (`~/.codex/sessions`) and Cursor
(`~/.cursor/projects/*/agent-transcripts`, and the Cursor app's
`~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`), and
keeps up to 200 project names, tool names and identifiers, most used first.
It writes `~/Library/Application Support/irudd-voice/vocabulary.json`
(`shared/vocabulary.schema.md`). Only terms are kept. Absolute paths, URLs,
code blocks and your account name are left out. `--dry-run` prints counts
only.

**`label`** sends each transcribed thought without an accepted label to a
teacher and stores the answer in `labels`. Only the transcript text and the
vocabulary are sent, and only when you run this command. It uses your
Claude or Codex subscription; `label` prints the cost Claude reports.

Each call runs from a new empty folder named `irudd-voice-teacher-…`,
locked down:

- Claude: `claude -p --tools "" --strict-mcp-config --no-session-persistence
  --disable-slash-commands --safe-mode --settings '{"disableAllHooks":true}'
  --system-prompt <teacher prompt> --json-schema <schema> --output-format json`
- Codex: `codex exec --ephemeral --ignore-user-config -s read-only
  --skip-git-repo-check --output-schema shared/teacher-reply.schema.json
  --json --color never -` (prompt on stdin)

A label is rejected, with the reason stored, when the reply is malformed
or empty, Codex ran a command or another tool, or the hard checks fail
(`shared/README.md`, "Hard checks"). A call that fails (the CLI exits with
an error or takes over 5 minutes) stores nothing, and `label` stops after 3
failed calls in a row. `label --dry-run` shows the count and the command
without calling anything.

**`dataset build`** gives every recording day a split (`dataset_days`):
about 15% of days go to test (at least 10%, at most 20%; one test day once
there are 3 days), about 10% to selection, the rest to train. A day keeps
its split forever, and labels on test days are frozen. It writes
`train.jsonl`, `valid.jsonl` (selection) and `test.jsonl` in mlx-lm's chat
format, plus `dataset.json` with the counts and `dataset_hash` (SHA-256 of
the prompt version and the sorted `split<TAB>line` lines). Without `--out`
it writes to a new temporary folder. `--augment-typed` adds, for each
accepted label in train and selection, the label as typed input and a
spoken-looking version (lowercase, no sentence punctuation, maybe a
filler). Test gets no variants, so it measures real dictation only.
