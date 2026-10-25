"""Speculative decoding drafters in model folders (docs/models/speculative.md).

A candidate with a drafter (gemma-4-e2b: Google's assistant) gets two extras
in every folder built for it, by `models prepare` and by `train`:

- `drafter/`: the drafter's config.json and weights from its pinned
  snapshot, named by the manifest's `drafter` field.
- What the drafter's target class needs. mlx-swift-lm only feeds Gemma 4's
  assistant from its MLXVLM Gemma 4 class, which wants `vision_config` and
  the vision tower's weights even for text. They are copied unchanged (bf16)
  from the base snapshot into model-vision.safetensors and added to the
  weight index. mlx-lm and the app's plain path drop them when loading.

The tensors are copied byte for byte with the small safetensors reader and
writer below, so this needs neither MLX nor a second copy in memory.
"""

from __future__ import annotations

import json
import shutil
import struct
from pathlib import Path

from .models import Candidate, ModelError, snapshot

VISION_WEIGHTS = "model-vision.safetensors"
VISION_PREFIXES = ("model.vision_tower.", "model.embed_vision.")
VISION_CONFIG_FILES = ("processor_config.json", "preprocessor_config.json")
DRAFTER_FILES = ("config.json", "model.safetensors")


def read_header(path: Path) -> tuple[dict, int]:
    """A safetensors file's header (each tensor's dtype, dimensions and byte
    range) and where its data starts."""
    with path.open("rb") as f:
        (size,) = struct.unpack("<Q", f.read(8))
        header = json.loads(f.read(size))
    return header, 8 + size


def copy_tensors(sources: list[Path], keep, out: Path) -> list[str]:
    """Writes the tensors whose names pass `keep`, from all `sources`, to one
    safetensors file. Returns their names; writes nothing when there are none."""
    picked = []
    for path in sources:
        header, start = read_header(path)
        for name, info in header.items():
            if name != "__metadata__" and keep(name):
                picked.append((name, info, path, start))
    if not picked:
        return []
    picked.sort(key=lambda item: item[0])
    header, offset = {}, 0
    for name, info, _, _ in picked:
        begin, end = info["data_offsets"]
        header[name] = {"dtype": info["dtype"], "shape": info["shape"], "data_offsets": [offset, offset + end - begin]}
        offset += end - begin
    header["__metadata__"] = {"format": "pt"}
    encoded = json.dumps(header, separators=(",", ":")).encode()
    encoded += b" " * (-len(encoded) % 8)
    with out.open("wb") as f:
        f.write(struct.pack("<Q", len(encoded)) + encoded)
        for _, info, path, start in picked:
            begin, end = info["data_offsets"]
            with path.open("rb") as source:
                source.seek(start + begin)
                remaining = end - begin
                while remaining:
                    block = source.read(min(remaining, 16 << 20))
                    if not block:
                        raise ModelError(f"{path} ends before its tensor data does")
                    f.write(block)
                    remaining -= len(block)
    return [name for name, _, _, _ in picked]


def add_vision_tower(folder: Path, source: Path) -> int:
    """Adds the base snapshot's vision tower to a converted Gemma folder:
    the weights, `vision_config`, the processor config and index entries.
    Returns the number of tensors added."""
    names = copy_tensors(sorted(source.glob("*.safetensors")), lambda n: n.startswith(VISION_PREFIXES),
                         folder / VISION_WEIGHTS)
    if not names:
        raise ModelError(f"{source} has no vision tower weights")
    config = json.loads((folder / "config.json").read_text())
    config["vision_config"] = json.loads((source / "config.json").read_text())["vision_config"]
    (folder / "config.json").write_text(json.dumps(config, indent=4) + "\n")
    index_path = folder / "model.safetensors.index.json"
    if index_path.exists():
        # The app loads the files the index names; without this it would
        # skip the vision weights.
        index = json.loads(index_path.read_text())
        index["weight_map"].update({name: VISION_WEIGHTS for name in names})
        index_path.write_text(json.dumps(index, indent=4) + "\n")
    for name in VISION_CONFIG_FILES:
        if (source / name).exists():
            shutil.copyfile(source / name, folder / name)
    return len(names)


def add_drafter(folder: Path, cand: Candidate, log=print) -> dict | None:
    """Adds the candidate's drafter (and the vision tower its target class
    needs) to a finished model folder, before the manifest is written.
    Returns the manifest's `drafter` field, or None for a candidate without one."""
    if cand.drafter is None:
        return None
    if cand.family != "gemma4":
        raise ModelError(f"no drafter support for the {cand.family} family")
    added = add_vision_tower(folder, snapshot(cand))
    drafter_source = snapshot(cand.drafter)
    target = folder / cand.drafter.folder
    target.mkdir()
    for name in DRAFTER_FILES:
        if not (drafter_source / name).exists():
            raise ModelError(f"{drafter_source} has no {name}")
        shutil.copyfile(drafter_source / name, target / name)
    log(f"added {added} vision tower tensors and the drafter {cand.drafter.repo}@{cand.drafter.revision[:12]}")
    return cand.drafter.entry()
