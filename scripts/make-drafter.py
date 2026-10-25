"""Builds Qwen3.5 MTP drafter folders for the speculative decoding
experiment (docs/models/speculative.md). Reads the pinned Hugging Face
snapshot; writes only to --out.

  uv run --project cli --group ml python scripts/make-drafter.py qwen-mtp \\
      --candidate qwen3.5-2b --out DIR [--bits 4]

Qwen3.5's own multi-token head (the 15 `mtp.*` tensors, which mlx-lm's
convert drops) as a drafter folder for mlx-swift-lm's Qwen35MTPDraftModel:
config.json (model_type qwen3_5, no vision_config) and model.safetensors with
the raw `mtp.*` weights. The norms stay as Hugging Face stores them; the
Swift side adds the +1 for model_type qwen3_5. With --bits 4 the linear
layers are quantized (group 64) like the base folders.

Gemma's drafter is part of the app's folder: `irudd-voice models prepare
gemma-4-e2b` builds it (cli/src/irudd_voice/drafter.py).
"""

import argparse
import json
import sys
from pathlib import Path

import mlx.core as mx

from irudd_voice import models

QWEN_LINEAR = ("fc", "q_proj", "k_proj", "v_proj", "o_proj", "gate_proj", "up_proj", "down_proj")


def snapshot_weights(folder: Path) -> dict:
    weights = {}
    for path in sorted(folder.glob("*.safetensors")):
        weights.update(mx.load(str(path)))
    return weights


def qwen_mtp(args) -> None:
    cand = models.candidate(args.candidate)
    source = models.snapshot(cand)
    hf_config = json.loads((source / "config.json").read_text())
    text = hf_config["text_config"]
    if text.get("mtp_num_hidden_layers", 0) < 1:
        sys.exit(f"{cand.repo} has no MTP layers")
    weights = {k: v for k, v in snapshot_weights(source).items() if k.startswith("mtp.")}
    if not weights:
        sys.exit(f"{source} has no mtp.* weights")
    config = {
        "model_type": "qwen3_5",
        "text_config": text,
        "tie_word_embeddings": hf_config.get("tie_word_embeddings", text.get("tie_word_embeddings", False)),
    }
    if args.bits:
        quantization = {"group_size": 64, "bits": args.bits}
        config["quantization"] = quantization
        config["quantization_config"] = quantization
        for key in [k for k in weights if k.endswith(".weight")]:
            if key.split(".")[-2] in QWEN_LINEAR and weights[key].ndim == 2:
                w, scales, biases = mx.quantize(weights[key], group_size=64, bits=args.bits)
                stem = key.removesuffix(".weight")
                weights[key], weights[f"{stem}.scales"], weights[f"{stem}.biases"] = w, scales, biases
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    (out / "config.json").write_text(json.dumps(config, indent=2) + "\n")
    mx.save_safetensors(str(out / "model.safetensors"), weights, metadata={"format": "mlx"})
    print(f"wrote {out}: {len(weights)} tensors from {cand.repo}@{cand.revision[:12]}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    qwen = commands.add_parser("qwen-mtp")
    qwen.add_argument("--candidate", required=True, choices=["qwen3.5-2b", "qwen3.5-4b"])
    qwen.add_argument("--out", required=True)
    qwen.add_argument("--bits", type=int, choices=[4, 8])
    args = parser.parse_args()
    qwen_mtp(args)


if __name__ == "__main__":
    main()
