# Model folders

Each model lives in `~/Library/Application Support/irudd-voice/models/<id>/`:

```
models/<id>/
  manifest.json
  config.json, tokenizer.json, tokenizer_config.json, chat_template.jinja (if any),
  generation_config.json (if any), model.safetensors (or shards + index)
  drafter/config.json, drafter/model.safetensors (with a drafter, see below)
```

The weights are MLX format and 4-bit quantized for the app. `<id>` matches
`[a-z0-9][a-z0-9.-]*` and has no `..`, for example `qwen3.5-2b-base-q4` or
`qwen3.5-2b-ft-20261025-1`.

`irudd-voice models prepare` creates the base folders from the pinned Hugging
Face snapshots. Training creates the fine-tuned ones. Both also insert a row
into the database's `models` table with the same `id` and the manifest JSON.
`active_model.model_id` refers to that row.

## manifest.json (schema 1)

```json
{
  "schema": 1,
  "id": "qwen3.5-2b-base-q4",
  "family": "qwen3_5",
  "base_repo": "Qwen/Qwen3.5-2B",
  "base_revision": "15852e8c16360a2fea060d615a32b45270f8a8fc",
  "source_repo": null,
  "source_revision": null,
  "tokenizer_sha256": "<sha256 of tokenizer.json>",
  "chat_template_sha256": "<sha256, see below>",
  "prompt_version": null,
  "quantization": {"bits": 4, "group_size": 64},
  "files": {"config.json": "<sha256>", "model.safetensors": "<sha256>", "tokenizer.json": "<sha256>"},
  "training": null,
  "drafter": null,
  "created_at": "2026-10-25T10:00:00Z"
}
```

- `files` lists **every file in the folder except `manifest.json`**, with
  its SHA-256, by path relative to the folder. The app verifies all of them
  before the first load of a folder it didn't create itself, and refuses
  the folder if any differ or are missing, or if the folder has a file the
  list doesn't have.
- **Dot files aren't part of a model folder.** A file is skipped when its
  name, or any parent folder's name inside the model folder, starts with
  "." (`.DS_Store`, `.cache/x`). A skipped file is never hashed, never
  required and never counts as unlisted, even if `files` lists it. Nothing
  else is skipped: a file with the macOS "hidden" flag but no leading dot
  is checked like any other.
- `id` must equal the folder's name. Loading by id refuses a folder whose
  manifest says otherwise.
- `chat_template_sha256`: SHA-256 of the bytes of `chat_template.jinja` if
  the folder has one, otherwise of the UTF-8 `chat_template` string in
  `tokenizer_config.json`.
- `source_repo` / `source_revision`: where a ready-made 4-bit folder can be
  downloaded from, or null. Not used yet: hosting the default model is a
  decision for later.
- `prompt_version`: null for untrained base models, which work with any
  prompt. A trained model records the prompt version it was trained on. The
  app only loads a trained model whose `prompt_version` equals the current
  `shared/cleanup-prompt.json` version. Changing the prompt's meaning means
  a new version, a retrain, and falling back to the base model until then.
- `training`: null for base models. For a trained model:

```json
{"method": "lora", "dataset_hash": "<sha256>", "chunks": 412, "layers": 16,
 "iterations": 600, "mlx_lm_version": "0.32.2", "trained_at": "..."}
```

- `drafter`: null (or missing, in folders written before it existed) for a
  model without one. Otherwise the drafter used for speculative decoding
  (`docs/models/speculative.md`):

```json
{"repo": "google/gemma-4-E2B-it-assistant",
 "revision": "2d874ef7d29f9a30599a1e4b3c1cbc9595f005df",
 "folder": "drafter", "draft_tokens": 3}
```

  `repo` and `revision` say where the drafter's files came from (a full
  commit hash). `folder` is a subfolder of the model folder holding the
  drafter's `config.json` and weights. It is one name matching the id rule
  above (`[a-z0-9][a-z0-9.-]*`, no `..`), so it can't leave the model folder
  or be skipped as a dot path. Its files are hashed in `files` like every
  other file (`drafter/config.json`, `drafter/model.safetensors`), and
  `<folder>/config.json` must be listed. `draft_tokens` is a whole number of
  at least 1: the tokens drafted per round. The app refuses a folder whose
  `drafter` breaks any of these rules. With a drafter, the app generates with
  speculative decoding; without one, it decodes one token at a time. When a
  valid entry's drafter doesn't load or can't start, the app still cleans,
  one token at a time, and logs why (a `cleanup` warning in `events`).

  Gemma 4's assistant drafts only for mlx-swift-lm's MLXVLM Gemma 4 class,
  so a Gemma folder with a drafter also holds the base model's vision tower:
  `vision_config` in config.json, `model-vision.safetensors` (listed in the
  weight index), and `processor_config.json`. mlx-lm and plain decoding drop
  those weights when they load.

The app refuses a folder whose manifest is missing or has an unknown `schema`.
