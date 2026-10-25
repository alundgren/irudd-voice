"""Builds the folders the speculative decoding experiment needs
(docs/models/speculative.md). Reads the pinned Hugging Face snapshots and the
base model folders; writes only to --out.

  uv run --project cli --group ml python scripts/make-drafter.py qwen-mtp \\
      --candidate qwen3.5-2b --out DIR [--bits 4]
  uv run --project cli --group ml python scripts/make-drafter.py gemma-target \\
      --model MODELS/gemma-4-e2b-base-q4 --out DIR/gemma-4-e2b-base-q4-vlm

qwen-mtp: Qwen3.5's own multi-token head (the 15 `mtp.*` tensors, which
mlx-lm's convert drops) as a drafter folder for mlx-swift-lm's
Qwen35MTPDraftModel: config.json (model_type qwen3_5, no vision_config) and
model.safetensors with the raw `mtp.*` weights. The norms stay as Hugging
Face stores them; the Swift side adds the +1 for model_type qwen3_5. With
--bits 4 the linear layers are quantized (group 64) like the base folders.

gemma-target: mlx-swift-lm only feeds the Gemma 4 assistant drafter from its
MLXVLM Gemma 4 class, which needs vision_config and the vision tower's
weights. This copies a base folder's files, adds the snapshot's vision tower
and embed_vision weights (bf16) as model-vision.safetensors, drops the
weight index so both weight files load, and writes a manifest.
"""

import argparse
import json
import shutil
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


def gemma_target(args) -> None:
    model = Path(args.model)
    manifest = models.read_manifest(model)
    cand = models.candidate_for(manifest)
    source = models.snapshot(cand)
    out = Path(args.out)
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    for name in models.model_files(model):
        if name != "model.safetensors.index.json":
            shutil.copy(model / name, out / name)
    hf_config = json.loads((source / "config.json").read_text())
    config = json.loads((model / "config.json").read_text())
    config["vision_config"] = hf_config["vision_config"]
    (out / "config.json").write_text(json.dumps(config, indent=2) + "\n")
    vision = {k: v for k, v in snapshot_weights(source).items()
              if k.startswith(("model.vision_tower.", "model.embed_vision."))}
    mx.save_safetensors(str(out / "model-vision.safetensors"), vision, metadata={"format": "mlx"})
    for name in ("processor_config.json", "preprocessor_config.json"):
        if (source / name).exists():
            shutil.copy(source / name, out / name)
    models.write_manifest(out, out.name, cand)
    print(f"wrote {out}: {len(vision)} vision tensors added")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    qwen = commands.add_parser("qwen-mtp")
    qwen.add_argument("--candidate", required=True, choices=["qwen3.5-2b", "qwen3.5-4b"])
    qwen.add_argument("--out", required=True)
    qwen.add_argument("--bits", type=int, choices=[4, 8])
    gemma = commands.add_parser("gemma-target")
    gemma.add_argument("--model", required=True)
    gemma.add_argument("--out", required=True)
    args = parser.parse_args()
    {"qwen-mtp": qwen_mtp, "gemma-target": gemma_target}[args.command](args)


if __name__ == "__main__":
    main()
