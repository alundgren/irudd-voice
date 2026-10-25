# Model runs

Reports from the Python model tools (`cli/README.md`, "Model tools"). Runs
on a MacBook Air M5 24 GB (fanless) with mlx 0.32.4 and mlx-lm 0.32.2, one
heavy job at a time. Each report records the hardware (from sysctl) and
`prompt_sha256` / `hardchecks_sha256`, so it can be matched to the prompt and
hard checks it was made with.

- `eval-<model>.json`: `irudd-voice eval <folder> --set all` for each
  untrained candidate: every reply, its hard-check failures, latency, and
  closeness to the expected output (transcripts).
- `parity-format.md`: the token file `irudd-voice parity-reference` writes
  for the Swift parity check.
- `speculative.md`: speculative decoding with a drafter (Gemma 4's
  assistant, Qwen3.5's MTP head): output checks, speed and the
  recommendation.

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

| Model | Questions with failures (of 40) | Transcripts with failures (of 50) | Mean closeness (transcripts) | p50 / p90 s (transcripts), first run | same, committed run |
| --- | --- | --- | --- | --- | --- |
| qwen3.5-2b-base-q4 | 4 | 6 | 0.915 | 0.40 / 0.44 | 0.44 / 0.52 |
| gemma-4-e2b-base-q4 | 0 | 4 | 0.918 | 0.36 / 0.42 | 0.63 / 0.74 |
| qwen3.5-4b-base-q4 | 1 | 3 | 0.924 | 0.97 / 1.10 | 1.20 / 1.34 |

The committed reports were made again to add the binding hashes; the
replies and failures are the same. The second run's latencies are higher
because the fanless Air had been training for a while before it; use the
Swift helper's benchmark for speed decisions.

Hard-check part of the baseline gate (0 question failures, at most 5
transcripts with failures): only gemma-4-e2b passes. Most transcript
failures are spoken corrections the model kept or resolved wrongly
("fifteen seconds. No, fifty seconds"), which the `numbers` check catches.
Some failures come from the checks being strict: `removed` → `remove`
counts as a new word, and `postgres` → `PostgreSQL` too.

## Tiny LoRA runs (2026-10-25)

`irudd-voice train --tiny <candidate>`: 36 training and 4 validation
synthetic examples, last 16 layers, rank 8, scale 20, learning rate 1e-5,
60 steps, batch 1, gradient checkpointing, loss on the reply tokens only.

| Candidate | Weights trained on | Training | Fuse + 4-bit | Peak memory | Validation loss (start → end) | Eval: questions / transcripts with failures |
| --- | --- | --- | --- | --- | --- | --- |
| qwen3.5-2b | bf16 | 168 s | 1 s | 6.7 GB | 0.201 → 0.002 | 2 / 8 |
| gemma-4-e2b | bf16 | 55 s | 2 s | 10.6 GB | 0.833 → 0.050 | 7 / 9 |
| qwen3.5-4b | 4-bit (QLoRA) | 500 s | 1 s | 7.9 GB | 0.150 → 0.003 | 1 / 3 |

- All three folders (`<candidate>-tiny-20261025`) verify, and their parity
  references were written. They overfit 40 examples and drop words ("Don't
  delete it."), so they test the training round trip; they are not better
  models.
- Which weights: bf16 when the text weights plus the non-embedding weights
  again fit in 60% of memory (14.4 GB here). Estimates: qwen3.5-2b 6.5 GB
  (measured peak 6.7), gemma-4-e2b 13.0 GB (5.5 of its 9.3 GB of text
  weights are embedding tables, counted once; measured 10.6),
  qwen3.5-4b 15.5 GB, so it trains on the 4-bit folder.
- Gated DeltaNet layers make Qwen LoRA slow: about 2.8 s per step on the 2B
  and 8 s on the 4B, against under 1 s for Gemma.

What went wrong on the way:

- mlx-lm 0.32.2's `default_loss` also counts the padding token after each
  example (ID 0). Qwen learns to predict it; Gemma's `<pad>` can't be fitted
  under its logit softcap, so Gemma's loss stalled at 0.85 with base
  Gemma already predicting the replies at 0.001. Training now passes its
  own loss that stops at the last real token.
- mlx-lm shuffles batches with numpy's global random state, which wasn't
  seeded. At learning rate 5e-5 for 80 steps, one batch order broke the 2B's
  spelling ("revers a string") and another didn't. Training seeds it now.
- During a DNS outage the 4B command took 59 minutes for 8 minutes of
  training: looking up the cached snapshot still asked the Hub. Cached
  pinned snapshots are now used without the network.
