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
uv run irudd-voice label [--teacher claude|codex] [--model M] [--limit N] [--db PATH] [--retry-rejected] [--dry-run]
uv run irudd-voice dataset build [--db PATH] [--out DIR] [--augment-typed]
```

**`vocab`** reads what you typed into Claude Code
(`~/.claude/projects`), Codex (`~/.codex/sessions`) and Cursor
(`~/.cursor/projects/*/agent-transcripts`, and the Cursor app's
`~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`), and
keeps up to 200 project names, tool names and identifiers, most used first.
It writes `~/Library/Application Support/irudd-voice/vocabulary.json`
(`shared/vocabulary.schema.md`). Only terms are kept. Code blocks, URLs,
emails, things that look like keys or tokens, host names, IP addresses,
absolute paths and your account name are left out. `--dry-run` prints
counts only.

**`label`** sends each transcribed thought without an accepted label to a
teacher and stores the answer in `labels`. Only the transcript text and the
vocabulary are sent, and only when you run this command. It uses your
Claude or Codex subscription; `label` prints the cost Claude reports.

Each call runs from a new empty folder named `irudd-voice-teacher-…`,
locked down:

- Claude: `claude -p --tools "" --strict-mcp-config --no-session-persistence
  --disable-slash-commands --safe-mode --settings '{"disableAllHooks":true}'
  --system-prompt <teacher prompt> --json-schema <schema> --output-format json`
- Codex: `codex exec --ephemeral --ignore-user-config --skip-git-repo-check
  --output-schema shared/teacher-reply.schema.json --json --color never
  -c web_search="disabled" -c default_permissions="irudd_voice_teacher"
  -c 'permissions.irudd_voice_teacher.filesystem={":minimal"="read", ":slash_tmp"="none"}'
  -c permissions.irudd_voice_teacher.network.enabled=false
  --disable shell_tool --disable unified_exec --disable view_image
  --disable image_generation --disable multi_agent --disable plugins
  --disable apps --disable hooks --disable computer_use --disable browser_use -`
  (prompt on stdin). With these flags Codex offers the model no shell tool.
  The permission profile means that anything it does run can read only
  system files: not your home folder, /tmp or other temp files, and with no
  network. The profile replaces `-s read-only`: when both are given, `-s`
  wins and the home folder is readable again.

To check this on your Mac without any model call (it uses `codex sandbox`
and a fake model server on 127.0.0.1). Run it again after every codex-cli
update, because new versions can add tools or change the sandbox:

```sh
uv run --project cli python scripts/codex-teacher-probe.py   # from the repo root
```

A label is rejected, with the reason stored, when the reply is malformed
or empty, Codex's event stream has any item other than a message,
reasoning, to-do list or error (`ran_command`), or the hard checks fail
(`shared/README.md`, "Hard checks"). A call that fails (the CLI exits with
an error or takes over 5 minutes) stores nothing, and `label` stops after 3
failed calls in a row. Thoughts already rejected under the current teacher
prompt are skipped; `--retry-rejected` asks again. `label --dry-run` shows the count and the command
without calling anything.

**`dataset build`** gives every recording day a split (`dataset_days`):
about 15% of days go to test (at least 10%, at most 20%; one test day once
there are 3 days), about 10% to selection, the rest to train. A day keeps
its split forever, and labels on test days are frozen. It writes
`train.jsonl`, `valid.jsonl` (selection) and `test.jsonl` in mlx-lm's chat
format, plus `dataset.json` with the counts and `dataset_hash` (SHA-256 of
the prompt version and the sorted `split<TAB>line` lines). Without `--out`
it writes to a new temporary folder. `dataset.json` also records
`vocabulary_hash` (SHA-256 of the terms used, one per line).
`--augment-typed` adds, for each accepted label in train, the label as
typed input and a spoken-looking version (lowercase, no sentence
punctuation, maybe a filler). Selection and test get no variants, so they
measure real dictation only.
