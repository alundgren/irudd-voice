"""Drafters in model folders: the vision tower copy, the drafter folder, the
manifest's drafter field, and train's use of them. No real model needed."""

import json
import struct
import sys
import types

import pytest

from irudd_voice import cli, drafter, models, train

GEMMA = models.candidate("gemma-4-e2b")


def write_safetensors(path, tensors):
    """A small safetensors file: name → (dtype, dimensions, raw bytes)."""
    header, data = {}, b""
    for name, (dtype, dims, raw) in tensors.items():
        header[name] = {"dtype": dtype, "shape": dims, "data_offsets": [len(data), len(data) + len(raw)]}
        data += raw
    encoded = json.dumps(header).encode()
    path.write_bytes(struct.pack("<Q", len(encoded)) + encoded + data)


def read_tensors(path):
    header, start = drafter.read_header(path)
    raw = path.read_bytes()
    return {name: (info["dtype"], info["shape"], raw[start + info["data_offsets"][0]:start + info["data_offsets"][1]])
            for name, info in header.items() if name != "__metadata__"}


@pytest.fixture
def snapshots(tmp_path, monkeypatch):
    """Fake pinned snapshots for Gemma and its assistant."""
    base = tmp_path / "gemma-snapshot"
    base.mkdir()
    write_safetensors(base / "model.safetensors", {
        "model.language_model.embed_tokens.weight": ("BF16", [2, 2], b"t" * 8),
        "model.vision_tower.encoder.layers.0.mlp.down_proj.linear.weight": ("BF16", [2], b"vv" * 2),
        "model.embed_vision.embedding_projection.weight": ("F32", [1], b"eeee"),
        "model.audio_tower.layers.0.weight": ("BF16", [1], b"aa"),
    })
    (base / "config.json").write_text(json.dumps({"model_type": "gemma4", "vision_config": {"hidden_size": 8}}))
    (base / "processor_config.json").write_text('{"processor_class": "Gemma4Processor"}')
    assistant = tmp_path / "assistant-snapshot"
    assistant.mkdir()
    (assistant / "config.json").write_text('{"model_type": "gemma4_assistant"}')
    (assistant / "model.safetensors").write_bytes(b"drafter weights")
    (assistant / "tokenizer.json").write_text("{}")
    monkeypatch.setattr(drafter, "snapshot", lambda pinned: assistant if pinned is GEMMA.drafter else base)
    return base, assistant


def converted_folder(path):
    """What mlx-lm's convert or save leaves: text weights, an index, no vision."""
    path.mkdir(parents=True)
    (path / "config.json").write_text(json.dumps({"model_type": "gemma4", "text_config": {}}))
    (path / "tokenizer.json").write_text('{"model": {}}')
    (path / "tokenizer_config.json").write_text("{}")
    (path / "chat_template.jinja").write_text("{{ messages }}")
    write_safetensors(path / "model.safetensors", {"language_model.model.embed_tokens.weight": ("U32", [1], b"qqqq")})
    (path / "model.safetensors.index.json").write_text(json.dumps(
        {"metadata": {}, "weight_map": {"language_model.model.embed_tokens.weight": "model.safetensors"}}))
    return path


def test_gemma_has_a_pinned_drafter_and_qwen_none():
    assert GEMMA.drafter.repo == "google/gemma-4-E2B-it-assistant"
    assert len(GEMMA.drafter.revision) == 40 and GEMMA.drafter.draft_tokens == 3
    assert GEMMA.drafter.entry() == {"repo": GEMMA.drafter.repo, "revision": GEMMA.drafter.revision,
                                     "folder": "drafter", "draft_tokens": 3}
    assert models.candidate("qwen3.5-2b").drafter is None and models.candidate("qwen3.5-4b").drafter is None


def test_copy_tensors_copies_bytes_exactly(tmp_path, snapshots):
    base, _ = snapshots
    names = drafter.copy_tensors([base / "model.safetensors"], lambda n: "vision" in n, tmp_path / "out.safetensors")
    assert names == ["model.embed_vision.embedding_projection.weight",
                     "model.vision_tower.encoder.layers.0.mlp.down_proj.linear.weight"]
    source = read_tensors(base / "model.safetensors")
    assert read_tensors(tmp_path / "out.safetensors") == {name: source[name] for name in names}
    # The header is padded to 8 bytes, as safetensors readers expect.
    assert struct.unpack("<Q", (tmp_path / "out.safetensors").read_bytes()[:8])[0] % 8 == 0
    assert drafter.copy_tensors([base / "model.safetensors"], lambda n: False, tmp_path / "none") == []
    assert not (tmp_path / "none").exists()


def test_add_drafter_builds_the_folder_the_app_needs(tmp_path, snapshots):
    folder = converted_folder(tmp_path / "gemma-4-e2b-base-q4")
    entry = drafter.add_drafter(folder, GEMMA, log=lambda line: None)
    assert entry == GEMMA.drafter.entry()
    vision = read_tensors(folder / "model-vision.safetensors")
    assert sorted(vision) == ["model.embed_vision.embedding_projection.weight",
                              "model.vision_tower.encoder.layers.0.mlp.down_proj.linear.weight"]
    assert json.loads((folder / "config.json").read_text())["vision_config"] == {"hidden_size": 8}
    weight_map = json.loads((folder / "model.safetensors.index.json").read_text())["weight_map"]
    assert weight_map["model.embed_vision.embedding_projection.weight"] == "model-vision.safetensors"
    assert weight_map["language_model.model.embed_tokens.weight"] == "model.safetensors"
    assert (folder / "processor_config.json").exists()
    # Only the drafter's config and weights, not its tokenizer.
    assert sorted(p.name for p in (folder / "drafter").iterdir()) == ["config.json", "model.safetensors"]

    manifest = models.write_manifest(folder, folder.name, GEMMA, drafter=entry)
    assert manifest["drafter"] == entry
    assert {"drafter/config.json", "drafter/model.safetensors", "model-vision.safetensors"} <= manifest["files"].keys()
    assert models.verify(folder) == []
    (folder / "drafter" / "model.safetensors").write_bytes(b"changed")
    assert models.verify(folder) == ["drafter/model.safetensors: checksum differs"]


def test_candidates_without_a_drafter_are_left_alone(tmp_path):
    folder = converted_folder(tmp_path / "m")
    before = sorted(p.name for p in folder.iterdir())
    assert drafter.add_drafter(folder, models.candidate("qwen3.5-2b")) is None
    assert sorted(p.name for p in folder.iterdir()) == before


def manifest_with(tmp_path, entry):
    folder = converted_folder(tmp_path / "gemma-4-e2b-base-q4")
    (folder / "drafter").mkdir()
    (folder / "drafter" / "config.json").write_text("{}")
    manifest = models.write_manifest(folder, folder.name, GEMMA, drafter=GEMMA.drafter.entry())
    manifest["drafter"] = entry
    (folder / "manifest.json").write_text(json.dumps(manifest))
    return folder


@pytest.mark.parametrize("change, problem", [
    ({"folder": "../elsewhere"}, "drafter.folder '../elsewhere' must match"),
    ({"folder": ".drafter"}, "drafter.folder '.drafter' must match"),
    ({"folder": "a/b"}, "drafter.folder 'a/b' must match"),
    ({"folder": "other"}, "drafter folder other/ has no config.json"),
    ({"draft_tokens": 0}, "draft_tokens must be a whole number of at least 1"),
    ({"draft_tokens": True}, "draft_tokens must be a whole number of at least 1"),
    ({"revision": ""}, "drafter.revision must be a non-empty string"),
    ("drafter", "drafter must be an object or null"),
])
def test_verify_refuses_a_bad_drafter_field(tmp_path, change, problem):
    entry = {**GEMMA.drafter.entry(), **change} if isinstance(change, dict) else change
    folder = manifest_with(tmp_path, entry)
    assert any(problem in p for p in models.verify(folder)), models.verify(folder)


def test_write_manifest_refuses_a_drafter_it_cant_find(tmp_path):
    folder = converted_folder(tmp_path / "m")
    with pytest.raises(models.ModelError, match="has no config.json"):
        models.write_manifest(folder, "m", GEMMA, drafter=GEMMA.drafter.entry())


def test_manifests_without_a_drafter_still_verify(tmp_path):
    folder = converted_folder(tmp_path / "qwen3.5-2b-base-q4")
    manifest = models.write_manifest(folder, folder.name, models.candidate("qwen3.5-2b"))
    assert manifest["drafter"] is None
    del manifest["drafter"]  # folders written before the field existed
    (folder / "manifest.json").write_text(json.dumps(manifest))
    assert models.verify(folder) == []


def test_prepare_wont_reuse_a_gemma_folder_without_its_drafter(tmp_path, capsys):
    folder = converted_folder(tmp_path / GEMMA.base_id)
    models.write_manifest(folder, folder.name, GEMMA)
    assert cli.main(["models", "prepare", "gemma-4-e2b", "--models-dir", str(tmp_path)]) == 1
    err = capsys.readouterr().err
    assert "its drafter is None, not google/gemma-4-E2B-it-assistant@" in err and "--force" in err


def test_prepare_reuses_a_gemma_folder_with_its_drafter(tmp_path, snapshots, capsys):
    folder = converted_folder(tmp_path / GEMMA.base_id)
    models.write_manifest(folder, folder.name, GEMMA, drafter=drafter.add_drafter(folder, GEMMA, log=print))
    assert cli.main(["models", "prepare", "gemma-4-e2b", "--models-dir", str(tmp_path)]) == 0
    assert "already prepared" in capsys.readouterr().err


def test_train_adds_the_drafter_to_a_gemma_folder(tmp_path, snapshots, monkeypatch):
    """train's real folder steps on a fake model: after fuse and save, the
    vision tower and the drafter are added and the manifest names them."""
    fake_utils = types.ModuleType("mlx_lm.utils")
    fake_utils.load = lambda source, return_config: (object(), object(), {})
    monkeypatch.setitem(sys.modules, "mlx_lm", types.ModuleType("mlx_lm"))
    monkeypatch.setitem(sys.modules, "mlx_lm.utils", fake_utils)
    monkeypatch.setattr(train, "choose_base", lambda cand, models_dir: (snapshots[0], "bf16"))
    monkeypatch.setattr(train, "train_lora", lambda *args, **kwargs: {"train": [(4, 1.0)], "valid": [(4, 1.1)],
                                                                       "peak_memory_gb": 1.0})
    monkeypatch.setattr(train, "fuse_and_save",
                        lambda model, tokenizer, config, source, staging, base_weights:
                        converted_folder(staging))
    monkeypatch.setattr(train, "package_version", lambda name: "0.32.2")
    result = train.train_tiny(GEMMA, tmp_path / "models", settings=train.LoraSettings(iterations=4))
    assert result.folder.name == train.tiny_model_id(GEMMA)
    assert result.manifest["drafter"] == GEMMA.drafter.entry()
    assert (result.folder / "drafter" / "model.safetensors").exists()
    assert (result.folder / "model-vision.safetensors").exists()
    assert models.verify(result.folder) == []
    # Fusing and copying the drafter are timed apart.
    assert {"fuse_seconds", "drafter_seconds"} <= result.timings.keys()


def test_train_without_a_drafter_records_no_drafter_time(tmp_path, monkeypatch):
    fake_utils = types.ModuleType("mlx_lm.utils")
    fake_utils.load = lambda source, return_config: (object(), object(), {})
    monkeypatch.setitem(sys.modules, "mlx_lm", types.ModuleType("mlx_lm"))
    monkeypatch.setitem(sys.modules, "mlx_lm.utils", fake_utils)
    qwen = models.candidate("qwen3.5-2b")
    monkeypatch.setattr(train, "choose_base", lambda cand, models_dir: (tmp_path, "bf16"))
    monkeypatch.setattr(train, "train_lora", lambda *args, **kwargs: {"train": [], "valid": [], "peak_memory_gb": 1.0})
    monkeypatch.setattr(train, "fuse_and_save",
                        lambda model, tokenizer, config, source, staging, base_weights: converted_folder(staging))
    monkeypatch.setattr(train, "package_version", lambda name: "0.32.2")
    result = train.train_tiny(qwen, tmp_path / "models", settings=train.LoraSettings(iterations=4))
    assert result.manifest["drafter"] is None and "drafter_seconds" not in result.timings
