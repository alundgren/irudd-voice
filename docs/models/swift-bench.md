# Swift model runner: speed, memory, evals and parity

Measured on 2026-10-25 on a MacBook Air M5 24 GB with `voice-model-tool`
(Packages/CleanupModel, Release build), which runs the same Swift code as the
XPC helper: CleanupEngine for generation, then the Swift reply parser and
hard checks. mlx-swift-lm 3.32.3 (MLX core 0.32.2), swift-transformers
1.3.5, the base 4-bit model folders from `irudd-voice models prepare`, and
prompt `cleanup-v1`. One model job ran at a time; other agents' builds may
have been running. Speed and evals were measured before the deadline check
and the `<|endoftext|>` stop token were added; neither changes a normal
cleanup's work.

## Speed and memory

Warm runs: 10 cleanups of the fixed 50-word transcripts in
`evals/bench.jsonl`, timed from the transcript going in to the hard checks
being done. The XPC round trip isn't included (in-process). Soak: the same
transcripts in a loop for 10 minutes right after the warm runs.

| Model | Warm p50 | Warm p90 | Runs ≤ 2 s | Cold load (verify + load + warm-up) | Peak memory | Soak (10 min): cleanups, p50 / p90, slowest, slowest in last minute |
| --- | --- | --- | --- | --- | --- | --- |
| qwen3.5-2b-base-q4 | 0.84 s | 0.87 s | 10/10 | 1.49 s (0.42 + 1.00 + 0.07) | 1.98 GB | 579, 1.01 / 1.18 s, 1.72 s, 1.27 s |
| gemma-4-e2b-base-q4 | 1.22 s | 1.39 s | 10/10 | 2.25 s (1.10 + 1.06 + 0.09) | 3.52 GB | 477, 1.25 / 1.36 s, 1.69 s, 1.67 s |
| qwen3.5-4b-base-q4 | 2.11 s | 2.25 s | 1/10 | 2.00 s (0.97 + 0.94 + 0.09) | 3.46 GB | 273, 2.18 / 2.33 s, 2.97 s, 2.97 s |

- Peak memory is the process's peak physical footprint (what Activity
  Monitor shows, Metal buffers included). MLX's own peak was 1.73, 3.10 and
  3.13 GB. All stay under the 6 GB bar.
- Cold load verifies every file's SHA-256 against the manifest first; the
  helper does this on every load unless told not to.
- Warm cleanups generated 57–65 tokens each on qwen3.5-2b.
- qwen3.5-4b misses the speed bar (2 s in 9 of 10 runs); the other two pass.

## Evals through the Swift path

`voice-model-tool eval` with the eval sets from the Python branch
(`evals/questions.jsonl`, 40 items; `evals/transcripts.jsonl`, 50 items; at
t3/py-models commit a06dab1). An item fails when the reply can't be read or
any hard check fails.

| Model | Questions passed | Questions failing checks | Transcripts passed | Transcripts failing checks |
| --- | --- | --- | --- | --- |
| qwen3.5-2b-base-q4 | 36/40 | question 2, new_words 2 | 44/50 | numbers 6, negation 2 |
| gemma-4-e2b-base-q4 | 40/40 | – | 46/50 | numbers 3, negation 1, new_words 1 |
| qwen3.5-4b-base-q4 | 39/40 | new_words 1 | 47/50 | numbers 3, negation 1, new_words 1 |

No model answered a question or carried out a command (no `answers`
failures), and every reply parsed (no think tags, cut-offs or malformed
JSON). Most transcript failures are spoken corrections the model kept or
dropped wrongly ("fifteen seconds no fifty seconds" left as both). The
`question` failures on qwen3.5-2b are questions returned without a "?".
The `new_words` failures include "postgres" → "PostgreSQL", which an
entry in the vocabulary would allow.

## Parity with Python mlx-lm

`tests/model-parity.sh` on the 20 inputs in `evals/parity.jsonl`, greedy, up
to 96 new tokens, against the Python references (mlx 0.32.4, mlx-lm 0.32.2,
regenerated 2026-10-25 12:16Z with `<|endoftext|>` as a Qwen stop token).
The strict result is identical tokens. The tie-aware result
(`tests/parity-gaps.py`) asks for identical prompt tokens and, where the
generated tokens differ, a gap of at most 0.5 between Python's logits for
its own token and for Swift's token at that step. The project owner accepted
the tie-aware rule on 2026-10-25, with one addition: at each difference,
Swift's token must be among Python's top 3 choices (top 3 rather than second,
because qwen3.5-2b p08 is a three-way near-tie: " dot" 18.5, " Python" 18.5,
" for" 18.375). Python's own token must also be the top score when its
reference is replayed, and both runs must share the model folder, inputs,
token limit and stop tokens. `tests/model-parity.sh` passes a model when its
tokens are identical or this rule holds; without a Python with mlx-lm to check
the rule, any difference fails.

| Model | Prompt tokens identical | Strict: generated tokens identical | Tie-aware |
| --- | --- | --- | --- |
| qwen3.5-2b-base-q4 | 20/20 | 19/20 (p08 differs at token 16) | pass (gap 0.125) |
| gemma-4-e2b-base-q4 | 20/20 | 18/20 (p07 at token 11, p13 at token 16) | pass (gaps 0.469, 0.281) |
| qwen3.5-4b-base-q4 | 20/20 | 20/20 | pass |
| qwen3.5-2b-tiny-20261025 | 20/20 | 20/20 | pass |
| gemma-4-e2b-tiny-20261025 | 20/20 | 20/20 | pass |
| qwen3.5-4b-tiny-20261025 | 20/20 | 20/20 | pass |

Each difference is one step where Swift picks another token, after which
the texts go their own way. Python's logits at those steps:

- qwen3.5-2b p08: " dot" 18.5, " Python" 18.5, " for" 18.375. Swift picked
  " for", one bf16 step below.
- gemma p07: `"}` 7.19 vs `."` 6.72 (gap 0.47); p13: `"}` 7.84 vs `."` 7.56
  (gap 0.28). Swift ended the sentence with a full stop.

The Qwen case is a near-tie. The Gemma gaps are several bf16 steps, so
mlx-swift-lm's Gemma 4 code and mlx-lm's round differently enough to
flip choices that aren't ties: numeric sensitivity, not only ties. The MLX
version doesn't explain it. Python mlx-lm with MLX 0.32.2 (the version
mlx-swift 0.32.3 bundles) also matched Swift on only 77 of 80 outputs (the
three base models and the first tiny model), so pinning MLX 0.32.2 wouldn't
help. Feeding the prompt the way
mlx-lm does (all tokens but the last, then the last) matched 75 of 80, so
the engine keeps mlx-swift-lm's one forward pass.
