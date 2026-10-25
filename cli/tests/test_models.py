"""Candidate table, manifest writing and verification. No real model needed."""

import hashlib
import json
import re
import sqlite3
import sys

import pytest

from irudd_voice import cli, models, train


def fake_folder(path, template="{{ messages }}"):
    path.mkdir()
    (path / "config.json").write_text('{"model_type": "qwen3_5"}')
    (path / "tokenizer.json").write_text('{"model": {}}')
    (path / "tokenizer_config.json").write_text('{"eos_token": "<|im_end|>"}')
    if template is not None:
        (path / "chat_template.jinja").write_text(template)
    (path / "model.safetensors").write_bytes(b"\x00" * 64)
    return path


def test_candidates_are_pinned():
    assert list(models.CANDIDATES) == ["qwen3.5-2b", "gemma-4-e2b", "qwen3.5-4b"]
    for cand in models.CANDIDATES.values():
        assert re.fullmatch(r"[0-9a-f]{40}", cand.revision)
        assert models.ID_PATTERN.fullmatch(cand.base_id)
        assert cand.family in train.LORA_KEYS
    assert models.candidate("gemma-4-e2b").repo == "google/gemma-4-E2B-it"
    with pytest.raises(models.ModelError, match="unknown candidate"):
        models.candidate("llama")


def test_manifest_lists_every_file(tmp_path):
    folder = fake_folder(tmp_path / "qwen3.5-2b-base-q4")
    manifest = models.write_manifest(folder, folder.name, models.candidate("qwen3.5-2b"), created_at="2026-10-25T10:00:00Z")
    assert manifest == json.loads((folder / "manifest.json").read_text())
    assert sorted(manifest["files"]) == ["chat_template.jinja", "config.json", "model.safetensors",
                                         "tokenizer.json", "tokenizer_config.json"]
    assert manifest["tokenizer_sha256"] == models.sha256_file(folder / "tokenizer.json")
    assert manifest["chat_template_sha256"] == models.sha256_file(folder / "chat_template.jinja")
    assert manifest["prompt_version"] is None and manifest["training"] is None
    assert manifest["quantization"] == {"bits": 4, "group_size": 64}
    assert manifest["schema"] == 1 and manifest["source_repo"] is None
    assert models.verify(folder) == []


def test_chat_template_from_tokenizer_config(tmp_path):
    folder = fake_folder(tmp_path / "m", template=None)
    (folder / "tokenizer_config.json").write_text(json.dumps({"chat_template": "{{ x }}"}))
    manifest = models.write_manifest(folder, "m", models.candidate("qwen3.5-2b"))
    assert manifest["chat_template_sha256"] == hashlib.sha256(b"{{ x }}").hexdigest()


def test_trained_model_needs_prompt_version(tmp_path):
    folder = fake_folder(tmp_path / "m")
    cand = models.candidate("qwen3.5-2b")
    with pytest.raises(models.ModelError, match="prompt_version"):
        models.write_manifest(folder, "m", cand, training={"method": "lora"})
    with pytest.raises(models.ModelError, match="must match"):
        models.write_manifest(folder, "Bad_Id", cand)


@pytest.mark.parametrize("tamper, problem", [
    (lambda f: (f / "model.safetensors").write_bytes(b"\x01" * 64), "model.safetensors: checksum differs"),
    (lambda f: (f / "config.json").unlink(), "config.json: missing"),
    (lambda f: (f / "extra.bin").write_bytes(b"x"), "extra.bin: not in the manifest"),
    (lambda f: (f / "chat_template.jinja").write_text("changed"), "chat_template.jinja: checksum differs"),
    (lambda f: (f / "manifest.json").unlink(), "has no manifest.json"),
    (lambda f: (f / "manifest.json").write_text('{"schema": 2}'), "unknown schema 2"),
])
def test_verify_detects_tampering(tmp_path, tamper, problem):
    folder = fake_folder(tmp_path / "qwen3.5-2b-base-q4")
    models.write_manifest(folder, folder.name, models.candidate("qwen3.5-2b"))
    tamper(folder)
    assert any(problem in p for p in models.verify(folder))


def test_verify_checks_the_folder_name(tmp_path):
    folder = fake_folder(tmp_path / "renamed")
    models.write_manifest(folder, "qwen3.5-2b-base-q4", models.candidate("qwen3.5-2b"))
    assert models.verify(folder) == ["manifest id 'qwen3.5-2b-base-q4' is not the folder name 'renamed'"]


def test_verify_command(tmp_path, capsys):
    folder = fake_folder(tmp_path / "qwen3.5-2b-base-q4")
    models.write_manifest(folder, folder.name, models.candidate("qwen3.5-2b"))
    assert cli.main(["models", "verify", str(folder)]) == 0
    (folder / "tokenizer.json").write_text("{}")
    assert cli.main(["models", "verify", str(folder)]) == 1
    assert "tokenizer.json: checksum differs" in capsys.readouterr().err


def test_install_folder_replaces_the_old_one(tmp_path):
    target = fake_folder(tmp_path / "m")
    staging = tmp_path / ".m.partial"
    staging.mkdir()
    (staging / "new").write_text("new")
    models.install_folder(staging, target)
    assert [p.name for p in target.iterdir()] == ["new"]
    assert not staging.exists() and not (tmp_path / ".m.old").exists()


def test_record_inserts_and_updates_the_row(tmp_path, app_db):
    folder = fake_folder(tmp_path / "qwen3.5-2b-base-q4")
    cand = models.candidate("qwen3.5-2b")
    first = models.write_manifest(folder, folder.name, cand, created_at="2026-10-25T10:00:00Z")
    models.record(app_db, first)
    con = sqlite3.connect(app_db)
    con.execute("PRAGMA foreign_keys = ON")
    con.execute("INSERT INTO active_model (slot, model_id, changed_at) VALUES (1, ?, '2026-10-25T10:00:00Z')",
                (folder.name,))
    con.commit()
    second = models.write_manifest(folder, folder.name, cand, created_at="2026-10-25T11:00:00Z")
    models.record(app_db, second)
    rows = con.execute("SELECT id, base_repo, base_revision, prompt_version, created_at, manifest_json FROM models").fetchall()
    assert len(rows) == 1
    assert rows[0][:5] == (folder.name, cand.repo, cand.revision, None, "2026-10-25T11:00:00Z")
    assert json.loads(rows[0][5]) == second
    assert con.execute("SELECT model_id FROM active_model").fetchone() == (folder.name,)


def test_model_commands_explain_the_ml_group(tmp_path, monkeypatch, capsys):
    monkeypatch.setitem(sys.modules, "mlx_lm", None)
    assert cli.main(["models", "prepare", "qwen3.5-2b", "--models-dir", str(tmp_path)]) == 1
    assert "uv run --group ml" in capsys.readouterr().err
    assert not any(tmp_path.iterdir())


def prepared(models_dir, cand_id="qwen3.5-2b"):
    cand = models.candidate(cand_id)
    models_dir.mkdir(exist_ok=True)
    folder = fake_folder(models_dir / cand.base_id)
    return folder, models.write_manifest(folder, folder.name, cand)


def model_rows(path):
    return sqlite3.connect(path).execute("SELECT id FROM models").fetchall()


def test_prepare_records_into_the_apps_database_by_default(tmp_path, app_db, monkeypatch, capsys):
    from irudd_voice import db

    monkeypatch.setattr(db, "DEFAULT_PATH", app_db)
    folder, _ = prepared(tmp_path / "models")
    # Already prepared: no MLX needed, but the row is still recorded.
    assert cli.main(["models", "prepare", "qwen3.5-2b", "--models-dir", str(tmp_path / "models")]) == 0
    assert model_rows(app_db) == [(folder.name,)]
    assert f"recorded {folder.name}" in capsys.readouterr().err


def test_prepare_skips_recording_without_an_app_database(tmp_path, capsys):
    prepared(tmp_path / "models")
    assert cli.main(["models", "prepare", "qwen3.5-2b", "--models-dir", str(tmp_path / "models")]) == 0
    assert "No database" in capsys.readouterr().err


def test_db_option_overrides_and_must_exist(tmp_path, app_db, capsys):
    folder, _ = prepared(tmp_path / "models")
    args = ["models", "prepare", "qwen3.5-2b", "--models-dir", str(tmp_path / "models")]
    assert cli.main([*args, "--db", str(app_db)]) == 0
    assert model_rows(app_db) == [(folder.name,)]
    assert cli.main([*args, "--db", str(tmp_path / "missing.sqlite")]) == 1
    assert "No database" in capsys.readouterr().err


def test_prepare_wont_reuse_a_folder_from_another_base(tmp_path, capsys):
    folder = fake_folder(tmp_path / "qwen3.5-2b-base-q4")
    models.write_manifest(folder, folder.name, models.candidate("qwen3.5-4b"))
    assert cli.main(["models", "prepare", "qwen3.5-2b", "--models-dir", str(tmp_path)]) == 1
    assert "Qwen/Qwen3.5-4B" in capsys.readouterr().err


def test_register_records_only_verified_folders(tmp_path, app_db, capsys):
    folder, _ = prepared(tmp_path)
    assert cli.main(["models", "register", str(folder), "--db", str(app_db)]) == 0
    assert model_rows(app_db) == [(folder.name,)]
    (folder / "config.json").write_text("{}")
    other = sqlite3.connect(app_db)
    other.execute("DELETE FROM models")
    other.commit()
    assert cli.main(["models", "register", str(folder), "--db", str(app_db)]) == 1
    assert "doesn't verify" in capsys.readouterr().err
    assert model_rows(app_db) == []


def test_dotfiles_are_not_part_of_a_model(tmp_path):
    folder = fake_folder(tmp_path / "qwen3.5-2b-base-q4")
    (folder / ".DS_Store").write_bytes(b"finder")
    (folder / ".cache").mkdir()
    (folder / ".cache" / "x.json").write_text("{}")
    manifest = models.write_manifest(folder, folder.name, models.candidate("qwen3.5-2b"))
    assert not any(name.startswith(".") for name in manifest["files"])
    assert ".cache/x.json" not in manifest["files"]
    # Dotfiles appearing, changing or vanishing later don't fail verification.
    (folder / ".DS_Store").unlink()
    (folder / "._model.safetensors").write_bytes(b"resource fork")
    assert models.verify(folder) == []
    # A real file still counts.
    (folder / "extra.bin").write_bytes(b"x")
    assert models.verify(folder) == ["extra.bin: not in the manifest"]
