# Default cleanup model (baseline pick)

Picked on 2026-10-25 from the three untrained candidates, all 4-bit, with the
shared prompt `cleanup-v1`. The numbers come from
`docs/models/eval-*-base-q4.json` (Python mlx-lm) and
`docs/models/swift-bench.md` (the app's Swift runner). Hardware: MacBook Air
M5, 24 GB.

## The rule (agreed in the plan)

A candidate passes when:

- it fails **no** hard check on the 40 questions and commands, so it never
  answers or carries out the request;
- **at most 5 of the 50** transcripts fail any hard check;
- it meets the speed bar: a warm 50-word cleanup in **2 s or less in 9 of 10
  runs**, with peak helper memory under 6 GB.

The default is the fastest candidate that passes. If none pass, the default is
the one with the fewest failures, and this file says so.

## Results

| Candidate | Questions failing (of 40) | Transcripts failing (of 50) | Warm 50-word p50 / p90 (Swift) | Runs ≤ 2 s | Peak memory | Passes |
| --- | --- | --- | --- | --- | --- | --- |
| **gemma-4-e2b-base-q4** | **0** | **4** (numbers 3, negation 1, new_words 1) | **1.22 / 1.39 s** | **10/10** | **3.52 GB** | **yes** |
| qwen3.5-2b-base-q4 | 4 (question 2, new_words 2) | 6 (numbers 6, negation 2) | 0.84 / 0.87 s | 10/10 | 1.98 GB | no: fails on questions, and 6 > 5 transcripts |
| qwen3.5-4b-base-q4 | 1 (new_words 1) | 3 | 2.11 / 2.25 s | 1/10 | 3.46 GB | no: too slow, and 1 question failure |

The Python and Swift evals agree on pass counts. No candidate ever answered a
question (no `answers` failures), and every reply could be read.

## Decision

**Default: `gemma-4-e2b-base-q4`** (google/gemma-4-E2B-it at revision
3e22461f65e89153144f8adb70e3b8c2cc9845a7). It is the only candidate that
passes. Its 10-minute soak held p90 at 1.36 s.

Its transcript failures are mostly spoken corrections the model resolved
wrongly ("fifteen seconds no fifty seconds" kept both). The hard checks catch
these, so the raw text is pasted instead. Fine-tuning on the user's own
labeled thoughts is meant to fix exactly this.

## Notes for training

- On the 24 GB Air, LoRA on Gemma 4 E2B ran on its bf16 weights with a
  10.6 GB peak (see `docs/models/README.md`).
- The last 16 layers of Gemma 4 E2B all share K/V with earlier layers, so
  LoRA only adapts their q/o projections and the MLP there.
