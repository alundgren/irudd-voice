# Model folders

Each model lives in `~/Library/Application Support/irudd-voice/models/<id>/`:

```
models/<id>/
  manifest.json
  config.json, tokenizer.json, tokenizer_config.json, chat_template.jinja (if any)
  model.safetensors (or model-0000x-of-0000y.safetensors + index)
```

The weights are MLX format, 4-bit quantized for the app. `<id>` is
lowercase letters, digits and dashes, e.g. `qwen3.5-2b-base-q4` or
`qwen3.5-2b-ft-20261025-1`.

## manifest.json (schema 1)

```json
{
  "schema": 1,
  "id": "qwen3.5-2b-base-q4",
  "family": "qwen3_5",
  "base_repo": "Qwen/Qwen3.5-2B",
  "base_revision": "15852e8c16360a2fea060d615a32b45270f8a8fc",
  "tokenizer_sha256": "<sha256 of tokenizer.json>",
  "chat_template_sha256": "<sha256 of the chat template text>",
  "prompt_version": "cleanup-v1",
  "quantization": {"bits": 4, "group_size": 64},
  "files": {"model.safetensors": "<sha256>", "config.json": "<sha256>"},
  "training": null,
  "created_at": "2026-10-25T10:00:00Z"
}
```

`training` is null for an untrained base model. For a trained model:

```json
{"method": "lora", "dataset_hash": "<sha256>", "chunks": 412,
 "layers": 16, "iterations": 600, "mlx_lm_version": "0.32.2",
 "trained_at": "..."}
```

The app checks every file in `files` against its SHA-256 before loading a
downloaded model, and refuses a folder whose manifest is missing, has an
unknown `schema`, or whose `prompt_version` doesn't match a prompt it has.
