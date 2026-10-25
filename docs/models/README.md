# Model runs

Reports from the Python model tools (`cli/README.md`, "Model tools"). Runs
on a MacBook Air M5 24 GB with mlx 0.32.4 and mlx-lm 0.32.2, one heavy job
at a time.

- `eval-<model>.json`: `irudd-voice eval <folder> --set all` for each
  untrained candidate: every reply, its hard-check failures, latency, and
  closeness to the expected output (transcripts).
- `parity-format.md`: the token file `irudd-voice parity-reference` writes
  for the Swift parity check.

## Prepare (2026-10-25)

| Candidate | Folder | Size | Convert time |
| --- | --- | --- | --- |
| qwen3.5-2b | `qwen3.5-2b-base-q4` | 1.0 GB | 3 s |
| gemma-4-e2b | `gemma-4-e2b-base-q4` | 2.5 GB | 7 s |
| qwen3.5-4b | `qwen3.5-4b-base-q4` | 2.2 GB | 4 s |

Snapshots were already in the Hugging Face cache, so this is conversion
only. Gemma's folder is bigger because its per-layer embeddings are large.

## Eval of the untrained candidates (2026-10-25)

Greedy, shared prompt `cleanup-v1`, warm model. Latency is the whole
generation for one item, in seconds, through Python mlx-lm (the app's Swift
helper is benchmarked separately).

| Model | Questions with failures (of 40) | Transcripts with failures (of 50) | Mean closeness (transcripts) | p50 / p90 s (transcripts) |
| --- | --- | --- | --- | --- |
| qwen3.5-2b-base-q4 | 4 | 6 | 0.915 | 0.40 / 0.44 |
| gemma-4-e2b-base-q4 | 0 | 4 | 0.918 | 0.36 / 0.42 |
| qwen3.5-4b-base-q4 | 1 | 3 | 0.924 | 0.97 / 1.10 |

Hard-check part of the baseline gate (0 question failures, at most 5
transcripts with failures): only gemma-4-e2b passes. Most transcript
failures are spoken corrections the model kept or resolved wrongly
("fifteen seconds. No, fifty seconds"), which the `numbers` check catches.
Some failures come from the checks being strict: `removed` → `remove`
counts as a new word, and `postgres` → `PostgreSQL` too.

## Tiny LoRA run (2026-10-25)

`irudd-voice train --tiny qwen3.5-2b`: 36 training and 4 validation
synthetic examples, bf16 weights, last 16 layers, rank 8, scale 20,
learning rate 1e-5, 60 steps, batch 1, gradient checkpointing.

- Training 200 s, fuse + 4-bit 1 s, peak memory 6.7 GB.
- Validation loss 1.709 → 0.002.
- `qwen3.5-2b-tiny-20261025` verifies and cleans the parity inputs
  sensibly. It overfits 40 examples, so it's a test of the training round
  trip, not a better model: on the eval sets it has 2 question and 7
  transcript failures.
- A first run at learning rate 5e-5 for 80 steps (270 s) broke spelling
  ("revers a string"). The same settings in a separate run were fine: mlx-lm
  shuffles batches with numpy's global random state, which wasn't seeded.
  Training now seeds it.
