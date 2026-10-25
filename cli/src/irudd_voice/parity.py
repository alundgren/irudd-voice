"""`irudd-voice parity-reference`: greedy token IDs from Python mlx-lm.

The Swift helper generates for the same inputs and compares token by token
(tests/model-parity.sh). The file format is documented in
docs/models/parity-format.md.
"""

from __future__ import annotations

import hashlib
import json
from importlib.metadata import version
from pathlib import Path

from .generation import Model, contract_hashes, read_jsonl

FORMAT = 1
MAX_NEW_TOKENS = 96
DEFAULT_INPUTS = Path(__file__).resolve().parents[3] / "evals" / "parity.jsonl"


def reference(folder: Path, inputs: Path = DEFAULT_INPUTS, max_new_tokens: int = MAX_NEW_TOKENS, log=print) -> dict:
    model = Model(folder)
    items = []
    for item in read_jsonl(inputs):
        terms = item.get("vocabulary", [])
        text = model.prompt_text(item["transcript"], terms)
        ids = model.encode(text)
        gen = model.generate(ids, max_new_tokens)
        log(f"{item['id']}: {len(ids)} prompt tokens, {len(gen.token_ids)} generated, {gen.seconds:.2f} s")
        items.append({
            "id": item["id"],
            "transcript": item["transcript"],
            "vocabulary": terms,
            "prompt": text,
            "prompt_token_ids": ids,
            "generated_token_ids": gen.token_ids,
            "stop_token_id": gen.stop_token_id,
            "text": gen.text,
        })
    return {
        "format": FORMAT,
        "model_id": model.manifest["id"],
        "manifest_sha256": hashlib.sha256((folder / "manifest.json").read_bytes()).hexdigest(),
        "prompt_version": model.prompt["version"],
        **contract_hashes(),
        "inputs_sha256": hashlib.sha256(inputs.read_bytes()).hexdigest(),
        "chat_template_options": model.prompt["chat_template_options"],
        "max_new_tokens": max_new_tokens,
        "stop_token_ids": sorted(model.stop_ids),
        "mlx_version": version("mlx"),
        "mlx_lm_version": version("mlx-lm"),
        "items": items,
    }


def write(result: dict, out: Path) -> None:
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(result, indent=1, ensure_ascii=False) + "\n")
