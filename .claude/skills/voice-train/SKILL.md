---
name: voice-train
description: Run a voice training run for irudd-voice - stats, labels, dataset, training, scoring, and promotion only after asking. Use when the user says "let's do a voice training run", "train the voice model", or asks to retrain, score or promote the cleanup model.
---

# Voice training run

Train a new cleanup model on the user's labeled thoughts, score it against the
active model, and promote it only if the user says yes. Run every command from
`cli/` in this repo. Commands that load a model need `--group ml`.

Keep the user posted in a line or two per step. Stop and report on any failure;
don't work around a refusal.

## 1. Stats

```sh
uv run irudd-voice stats
uv run irudd-voice models status
```

Tell the user how many thoughts and accepted labels there are, and which
model is active.

## 2. Labels

Ask which teacher to use if it isn't obvious (Claude by default; keep the same
teacher as earlier labels). Labeling sends the transcript text to that CLI and
costs a little. Show the plan first, then run it:

```sh
uv run irudd-voice label --teacher claude --dry-run
uv run irudd-voice label --teacher claude
```

## 3. Dataset

```sh
uv run irudd-voice dataset build --out "$TMPDIR/voice-dataset"
```

Report the train / selection / test counts. Training needs at least one
selection example; promotion needs at least 100 test thoughts.

## 4. Train

Say that dictation keeps working while training runs, but pastes raw text
until the model is back. Then:

```sh
uv run --group ml irudd-voice train --dataset "$TMPDIR/voice-dataset"
```

It runs at low priority and can take a long time; run it in the background and
check on it. If it stops because the app didn't unload its model, tell the user
to wait until no thought is in progress (or quit the app) and run it again.
Note the `model_id` it prints.

## 5. Score

Use the same teacher as the labels:

```sh
uv run --group ml irudd-voice eval-compare <model_id> --teacher claude
```

Show the votes, hard-check line, closeness and the "Promotable" answer with its
reasons.

## 6. Spot check (optional)

Offer it; skipping it is fine. It runs in the user's own terminal because it
asks them to pick A or B:

```sh
uv run irudd-voice spot-check <model_id>
```

## 7. Promote: ask first

Never promote without the user's explicit yes in this conversation. If the
report says it isn't promotable, say why and stop. If it is, ask. On yes:

```sh
uv run irudd-voice promote <model_id>
```

It says whether the app has loaded the new model. To undo:
`uv run irudd-voice rollback`.

## 8. Clean up

The dataset folder holds the user's text. Delete it when the run is over,
whatever the outcome:

```sh
rm -rf "$TMPDIR/voice-dataset"
```
