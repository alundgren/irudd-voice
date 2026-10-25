# Speculative decoding: faster cleanup with a drafter

Measured on 2026-10-25 on a MacBook Air M5 24 GB with `voice-model-tool`
(Release build, mlx-swift-lm 3.32.3), prompt `cleanup-v1`, the base 4-bit
model folders. One model job ran at a time.

**Short version:** Gemma 4 E2B with Google's assistant drafter (3 draft
tokens) cleans a 50-word thought in **0.39 s** instead of **0.97–1.20 s**,
about 2.5 to 3 times faster, with the same eval pass counts. Qwen3.5's
built-in multi-token head helps much less (about 15%). The output is
**not** always token-identical to plain greedy: 1 to 4 items in 110 change
at one near-tied token. The app is not wired up yet (see "App wiring").

## How it works

A small drafter guesses the next few tokens. The cleanup model then scores
all of them in one forward pass and keeps the guesses up to the first one it
disagrees with, plus its own token at that spot. With greedy decoding, every
token that is kept is the one the model picked itself, so in exact
arithmetic the text can't change. Only the speed changes: one forward pass
now yields several tokens.

mlx-swift-lm 3.32.3 does this in `MTPSpeculativeTokenIterator`. Two drafters
fit our candidates:

- **Gemma 4 E2B:** `google/gemma-4-E2B-it-assistant` at revision
  `2d874ef7d29f9a30599a1e4b3c1cbc9595f005df` (Apache-2.0, 78M parameters,
  190 MB bf16). It reads the target's own K/V cache, so it is very cheap.
  mlx-swift-lm only feeds it from **MLXVLM's** Gemma 4 class, not the MLXLLM
  class the app uses today. That class needs `vision_config` and the vision
  tower's weights in the model folder (168M parameters, 340 MB bf16), even
  though they are never used for text.
- **Qwen3.5 2B/4B:** the models' own MTP head (the 15 `mtp.*` tensors in the
  Hugging Face snapshot, which mlx-lm's convert drops). mlx-swift-lm caps it
  at **1 draft token per round** (`Qwen35MTPDraftModel.maximumBlockSize` is
  2), so `--draft-tokens 2/3/4` all run as 1.

`scripts/make-drafter.py` builds the folders: `qwen-mtp` writes a Qwen
drafter folder (bf16, or 4-bit with `--bits 4`), and `gemma-target` copies a
Gemma base folder and adds the vision tower so MLXVLM can load it. The Gemma
assistant loads straight from its Hugging Face snapshot.

`voice-model-tool generate|eval|bench` take `--draft DIR` and
`--draft-tokens N`. `--draft-tokens 0` loads the model the way the drafter
needs it (for Gemma, the MLXVLM class) but generates one token at a time.
That separates "different model class" from "drafting" when outputs differ.

## Does the output stay the same?

Each run below was compared with plain greedy on the same inputs:
`evals/parity.jsonl` (20 items, token IDs), and the replies of
`evals/questions.jsonl` (40) and `evals/transcripts.jsonl` (50).

| Pairing | Compared with | Parity tokens identical | Question replies identical | Transcript replies identical |
| --- | --- | --- | --- | --- |
| Gemma, MLXVLM class, no drafter | Gemma as the app runs it today (MLXLLM class) | 19/20 (p07) | 37/40 (q02, q08, q28) | 49/50 (t44) |
| Gemma + assistant, 2 draft tokens | Gemma, MLXVLM class, no drafter | 20/20 | 40/40 | 49/50 (t44) |
| Gemma + assistant, 3 draft tokens | Gemma, MLXVLM class, no drafter | 20/20 | 40/40 | 49/50 (t44) |
| Gemma + assistant, 4 draft tokens | Gemma, MLXVLM class, no drafter | 19/20 (p07) | 39/40 (q02) | 49/50 (t44) |
| Gemma + assistant, 3 draft tokens | Gemma as the app runs it today | 19/20 (p07) | 37/40 (q02, q08, q28) | 50/50 |
| Qwen3.5 2B + MTP (bf16 or 4-bit) | Qwen3.5 2B, no drafter | 19/20 (p08) | 39/40 (q22) | 49/50 (t49) |
| Qwen3.5 4B + MTP (bf16 or 4-bit) | Qwen3.5 4B, no drafter | 20/20 | 40/40 | 49/50 (t04) |

Each difference is one token where the two runs pick differently, after
which the texts go their own way. Every one is a near-tie. The scores below
are Python mlx-lm's logits at that step (`tests/parity-gaps.py`, replaying
the plain run's tokens):

| Item | Plain run's token | Drafted run's token | Gap |
| --- | --- | --- | --- |
| Gemma q02, p07 | `."` 6.72 | `"}` 7.19 | drafted token scores 0.47 higher |
| Gemma q08 | `."` 5.59 | `"}` 6.56 | drafted token scores 0.97 higher |
| Gemma q28 | `"}` 5.88 | `."` 6.41 | drafted token scores 0.53 higher |
| Gemma t44 (vs MLXVLM plain) | ` one` −2.20 | ` point` −1.98 | drafted token scores 0.23 higher |
| Qwen 2B q22 | ` remove` 25.5 | ` removed` 25.5 | exact tie |
| Qwen 2B t49 | ` should` 22.75 | ` shouldn` 22.88 | drafted token scores 0.13 higher |
| Qwen 2B p08 | ` for` 18.375 | ` Python` 18.5 | drafted token scores 0.13 higher |
| Qwen 4B t04 | ` ` 24.0 | ` four` 24.0 | exact tie |

In every case the drafted run's token is Python's first choice or tied
with it. Most Gemma differences are whether the sentence ends with a full
stop. The cause is batched verification: the target scores the bonus
token and 1 to 4 drafts in one forward pass, and those matrix kernels round
differently from one-token steps. Only the target's logits pick the emitted
tokens, so the drafter can't change the text in any other way. Which items
flip also depends on how many tokens are verified at once (p07 and q02 flip
only with 4 draft tokens). This is the same kind of difference the project
accepted for Swift against Python (`swift-bench.md`, tie-aware rule).

Hard-check pass counts never got worse:

| Model | Questions passed, plain → drafted | Transcripts passed, plain → drafted |
| --- | --- | --- |
| Gemma 4 E2B (2, 3 or 4 draft tokens) | 40/40 → 40/40 | 46/50 → 46/50 |
| Qwen3.5 2B (MTP bf16 or 4-bit) | 36/40 → 37/40 (q22 no longer adds a word) | 44/50 → 44/50 |
| Qwen3.5 4B (MTP bf16 or 4-bit) | 39/40 → 39/40 | 47/50 → 47/50 |

The token limit and stop tokens behave the same: with `--max-tokens 6` or
`7`, drafted and plain runs stopped at the same token on all 20 parity
inputs. The deadline is checked after every token as before. Drafted tokens
arrive a few at a time, so a cleanup can run up to one round (one forward
pass, tens of milliseconds) past its deadline.

## Speed and memory

`voice-model-tool bench`, 10 warm runs each on `evals/bench.jsonl` (50
words) and `evals/bench-20.jsonl` (20 words), from transcript in to hard
checks done. Peak memory is the process's peak physical footprint.
Acceptance is accepted drafts / proposed drafts over the 10 50-word runs.

The Air has no fan and was warming up through the session. Each model's
plain run was measured before and after its drafted runs ("again"). Plain
Gemma went from 0.97 to 1.20 s, so compare within a model, not with older
tables.

| Pairing | 50 words p50 / p90 | Runs ≤ 2 s | 20 words p50 / p90 | Cold load: verify + load + warm-up | Peak memory | Acceptance |
| --- | --- | --- | --- | --- | --- | --- |
| Gemma, as the app runs it today | 0.97 / 1.01 s | 10/10 | 0.54 / 0.55 s | 1.05 + 0.99 + 0.08 s | 3.52 GB | – |
| Gemma, MLXVLM class, no drafter | 0.80 / 0.86 s | 10/10 | 0.41 / 0.43 s | 1.20 + 1.12 + 0.08 s | 3.48 GB | – |
| Gemma + assistant, 2 draft tokens | 0.44 / 0.46 s | 10/10 | 0.23 / 0.25 s | 1.17 + 1.14 + 0.09 s | 3.68 GB | 92% |
| **Gemma + assistant, 3 draft tokens** | **0.39 / 0.44 s** | **10/10** | **0.22 / 0.22 s** | 1.21 + 1.15 + 0.09 s | 3.68 GB | 88% |
| Gemma + assistant, 4 draft tokens | 0.45 / 0.52 s | 10/10 | 0.27 / 0.29 s | 1.14 + 1.22 + 0.08 s | 3.68 GB | 83% |
| Gemma, as the app runs it today (again) | 1.20 / 1.37 s | 10/10 | 0.67 / 0.76 s | 1.10 + 1.08 + 0.09 s | 3.53 GB | – |
| Qwen3.5 2B, no drafter | 1.02 / 1.10 s | 10/10 | 0.56 / 0.64 s | 0.44 + 0.67 + 0.06 s | 1.99 GB | – |
| Qwen3.5 2B + MTP bf16 | 0.86 / 1.03 s | 10/10 | 0.50 / 0.55 s | 0.44 + 0.68 + 0.06 s | 2.11 GB | 96% |
| Qwen3.5 2B + MTP 4-bit | 0.83 / 0.95 s | 10/10 | 0.52 / 0.56 s | 0.44 + 0.73 + 0.06 s | 2.04 GB | 97% |
| Qwen3.5 2B, no drafter (again) | 0.98 / 1.05 s | 10/10 | 0.56 / 0.63 s | 0.42 + 0.67 + 0.06 s | 1.99 GB | – |
| Qwen3.5 4B, no drafter | 2.16 / 2.21 s | 1/10 | 1.29 / 1.40 s | 0.99 + 0.67 + 0.16 s | 3.49 GB | – |
| Qwen3.5 4B + MTP bf16 | 1.81 / 2.00 s | 9/10 | 1.10 / 1.13 s | 0.99 + 0.74 + 0.08 s | 3.73 GB | 99% |
| Qwen3.5 4B + MTP 4-bit | 1.81 / 1.90 s | 9/10 | 1.14 / 1.28 s | 0.94 + 0.69 + 0.08 s | 3.57 GB | 99% |
| Qwen3.5 4B, no drafter (again) | 2.19 / 2.28 s | 0/10 | 1.31 / 1.43 s | 0.91 + 0.67 + 0.09 s | 3.47 GB | – |

- Best draft count for Gemma: **3**. Two accepts more often but saves
  less per round. Four wastes more rejected drafts.
- The MLXVLM Gemma class is itself about 17% faster than the MLXLLM class,
  even without a drafter.
- The Gemma drafter adds about 0.16 GB peak memory (the vision tower is
  loaded but never run). Cold load stays near 2.4 s.
- Qwen's MTP head is right 96–99% of the time, but one draft per round
  only saves about 15%. Its 4-bit and bf16 heads accept equally often; 4-bit
  is smaller (33 MB / 65 MB against 116 MB / 230 MB) and no slower.

## Recommendation

Use **Gemma 4 E2B + its assistant drafter, 3 draft tokens**. It is the
only option that passes the agreed rule (`baseline.md`: 0 question
failures, at most 5 of 50 transcripts, ≤ 2 s in 9 of 10), and it now
cleans 50 words in 0.39 s (p90 0.44 s) and 20 words in 0.22 s.

The default model doesn't change. The options that pass the rule, and
their speed:

| Option | Passes the rule | 50 words p50 / p90 |
| --- | --- | --- |
| Gemma 4 E2B + assistant, 3 draft tokens | yes (0 questions, 4 transcripts) | 0.39 / 0.44 s |
| Gemma 4 E2B, no drafter (today) | yes (0 questions, 4 transcripts) | 0.97–1.20 / 1.01–1.37 s |
| Qwen3.5 4B + MTP | no: 1 question failure, though it now meets the speed bar (9/10) | 1.81 / 1.90 s |
| Qwen3.5 2B ± MTP | no: 3–4 question failures and 6 transcripts | 0.83 / 0.95 s |

The output differences are near-ties of the kind the tie-aware parity rule
already accepts. They are not exact, though, so the project owner should
decide whether drafted output counts as "the same" before it ships.

## App wiring: not done

The brief asked for app wiring only when outputs are identical and the
change is clean. Neither holds:

1. Outputs differ on 1–4 of 110 items (above). They are near-ties, but not
   identical tokens.
2. For Gemma, the drafter isn't just an extra folder. The model folder
   itself must change: it needs `vision_config` and 340 MB of vision tower
   weights, and must load through MLXVLM instead of MLXLLM. That changes
   `irudd-voice models prepare`, the manifests of existing folders, and the
   training output. `train` fuses LoRA through mlx-lm, which drops the
   vision tower, so every trained model would need the tower added back.
   It also changes plain greedy output on 5 of 110 items through the class
   switch alone.

Wiring only the Qwen MTP head would be clean (a separate drafter folder,
same model class), but no Qwen model passes the rule, so the app wouldn't
use it.

Ways forward, if the owner accepts near-tie differences:

- Wire Gemma as it is: `models prepare` builds the MLXVLM folder (as
  `scripts/make-drafter.py gemma-target` does) and fetches the pinned
  assistant. The manifest gets an optional `drafter` entry, and training adds
  the vision tower back after fusing.
- Or first get mlx-swift-lm's MLXLLM Gemma 4 class to emit the drafter
  state (an upstream change), so the folders stay as they are.

## Reproducing

```
uv run --project cli --group ml python scripts/make-drafter.py qwen-mtp --candidate qwen3.5-2b --out DIR/qwen3.5-2b-mtp-q4 --bits 4
uv run --project cli --group ml python scripts/make-drafter.py gemma-target --model MODELS/gemma-4-e2b-base-q4 --out DIR/gemma-4-e2b-base-q4-vlm
hf download google/gemma-4-E2B-it-assistant --revision 2d874ef7d29f9a30599a1e4b3c1cbc9595f005df

voice-model-tool bench --model DIR/gemma-4-e2b-base-q4-vlm --draft ASSISTANT_SNAPSHOT --draft-tokens 3
voice-model-tool generate --model DIR/gemma-4-e2b-base-q4-vlm --draft ASSISTANT_SNAPSHOT --draft-tokens 3 --out drafted.json
voice-model-tool generate --model DIR/gemma-4-e2b-base-q4-vlm --draft ASSISTANT_SNAPSHOT --draft-tokens 0 --out plain.json
voice-model-tool compare --reference plain.json --swift drafted.json
```
