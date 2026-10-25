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

## Model tools

The model commands need MLX, which lives in the `ml` dependency group so
`stats` stays light. Run them with `uv run --group ml`:

```sh
cd cli
uv run --group ml irudd-voice models prepare qwen3.5-2b   # pinned HF snapshot → 4-bit model folder
uv run irudd-voice models verify ~/Library/Application\ Support/irudd-voice/models/qwen3.5-2b-base-q4
uv run irudd-voice models register <model-folder>            # record an existing folder in the models table
uv run --group ml irudd-voice train --tiny qwen3.5-2b      # 40 synthetic examples, checks the training round trip
uv run --group ml irudd-voice eval <model-folder> --set all --out report.json
uv run --group ml irudd-voice parity-reference <model-folder> --out tokens.json
```

- `models prepare <candidate>` downloads the pinned snapshot if it isn't in
  the Hugging Face cache, converts it with mlx-lm (text only, 4-bit, group
  64) into `<models-dir>/<candidate>-base-q4/` and writes `manifest.json`
  (shared/manifest.schema.md). An existing folder is reused if it verifies
  and was built from the same pinned snapshot. Candidates: `qwen3.5-2b`,
  `gemma-4-e2b`, `qwen3.5-4b`.
- `models prepare` records the folder in the `models` table of the app's
  database (if the app has created it; otherwise it says so and skips it).
  `--db PATH` uses another database. `models register <folder>` verifies a
  folder and records it. `train --tiny` records its test model only when
  `--db` is given, so it never shows up as a trained model in the app.
- `train --tiny` trains LoRA on the bf16 weights (the 4-bit folder if bf16
  wouldn't fit in 60% of memory: text weights plus the non-embedding weights
  again), fuses, quantizes and writes
  `<candidate>-tiny-<date>/` with a `training` block in its manifest.
- `eval` runs the fixed sets in `evals/` through the shared prompt, the
  reply parser and the hard checks, and scores transcripts against their
  expected output.
- `parity-reference` writes greedy token IDs for `evals/parity.jsonl`
  (format: docs/models/parity-format.md) for the Swift parity check.

Slow tests that load a real model run only on request:
`IRUDD_VOICE_SLOW=1 uv run --group ml pytest -m slow`.

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
