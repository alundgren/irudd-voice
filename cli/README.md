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
uv run --group ml irudd-voice train --tiny qwen3.5-2b      # 40 synthetic examples, checks the training round trip
uv run --group ml irudd-voice eval <model-folder> --set all --out report.json
uv run --group ml irudd-voice parity-reference <model-folder> --out tokens.json
```

- `models prepare <candidate>` downloads the pinned snapshot if it isn't in
  the Hugging Face cache, converts it with mlx-lm (text only, 4-bit, group
  64) into `<models-dir>/<candidate>-base-q4/` and writes `manifest.json`
  (shared/manifest.schema.md). `--db PATH` also records the folder in the
  `models` table. Candidates: `qwen3.5-2b`, `gemma-4-e2b`, `qwen3.5-4b`.
- `train --tiny` trains LoRA on the bf16 weights (the 4-bit folder if bf16
  wouldn't fit in memory), fuses, quantizes and writes
  `<candidate>-tiny-<date>/` with a `training` block in its manifest.
- `eval` runs the fixed sets in `evals/` through the shared prompt, the
  reply parser and the hard checks, and scores transcripts against their
  expected output.
- `parity-reference` writes greedy token IDs for `evals/parity.jsonl`
  (format: docs/models/parity-format.md) for the Swift parity check.

Slow tests that load a real model run only on request:
`IRUDD_VOICE_SLOW=1 uv run --group ml pytest -m slow`.
