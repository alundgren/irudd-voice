"""One real training run and eval-compare on synthetic labeled thoughts:
real LoRA on gemma-4-e2b and both real models generating, a fake judge.
Needs the ml group, the pinned gemma snapshot in the Hugging Face cache and
the prepared gemma-4-e2b-base-q4 folder; takes a few minutes and ~11 GB."""

import json
import os
from pathlib import Path

import pytest
from labeling import add_chunk, add_label, rows
from trainloop import FakeJudge

from irudd_voice import cli, compare, dataset, db, models, train

pytestmark = [
    pytest.mark.slow,
    pytest.mark.skipif(not os.environ.get("IRUDD_VOICE_SLOW"), reason="real model; set IRUDD_VOICE_SLOW=1"),
]

APP_MODELS = Path.home() / "Library" / "Application Support" / "irudd-voice" / "models"


def test_train_and_eval_compare_end_to_end(app_db, tmp_path, monkeypatch, capsys):
    pytest.importorskip("mlx_lm")
    base = APP_MODELS / models.default_model_id()
    if not base.exists():
        pytest.skip(f"{base} isn't prepared")
    models_dir = tmp_path / "models"
    models_dir.mkdir()
    # The base folder is only read; a link keeps the 2.5 GB in place.
    (models_dir / base.name).symlink_to(base)
    models.record(app_db, models.read_manifest(base))
    no_vocabulary = tmp_path / "no-vocabulary.json"

    # 20 synthetic thoughts with teacher-style labels, two per day.
    for n, (spoken, cleaned) in enumerate(train.TINY_REQUESTS):
        chunk_id = add_chunk(app_db, "um " + spoken, day=f"2026-10-{n // 2 + 1:02d}")
        add_label(app_db, chunk_id, cleaned)
    data = tmp_path / "dataset"
    con = db.connect(app_db, write=True)
    summary = dataset.build(con, data, [])
    con.close()
    assert all(summary["examples"].values()), summary["examples"]

    assert cli.main(["train", "--db", str(app_db), "--models-dir", str(models_dir), "--dataset", str(data),
                     "--iterations", "8"]) == 0
    result = json.loads(capsys.readouterr().out)
    model_id = result["model_id"]
    assert model_id.startswith("gemma-4-e2b-ft-") and model_id.endswith("-1")
    assert models.verify(models_dir / model_id) == []
    training = result["training"]
    assert training["dataset_hash"] == summary["dataset_hash"]
    assert training["chunks"] == summary["examples"]["train"]
    assert training["candidate"] == "gemma-4-e2b" and training["iterations"] == 8
    assert rows(app_db, "SELECT trained_chunks, dataset_hash FROM models WHERE id = ?", (model_id,)) == [
        (summary["examples"]["train"], summary["dataset_hash"])]
    assert rows(app_db, "SELECT key FROM app_state WHERE key = 'cleanup.unload_until'") == []

    judge = FakeJudge(tmp_path, monkeypatch)
    judge.rule("*", always="A")  # every decided-looking vote is an order disagreement
    assert cli.main(["eval-compare", model_id, "--db", str(app_db), "--models-dir", str(models_dir),
                     "--vocabulary", str(no_vocabulary)]) == 0
    out = capsys.readouterr().out
    report = json.loads(rows(app_db, "SELECT eval_report_json FROM models WHERE id = ?", (model_id,))[0][0])
    con = db.connect(app_db)
    assert report["summary"]["compared"] == len(compare.test_thoughts(con)) == summary["examples"]["test"]
    con.close()
    assert report["incumbent"]["id"] == base.name
    assert report["summary"]["votes"]["win"] == report["summary"]["votes"]["loss"] == 0
    for item in report["items"]:
        for side in ("candidate", "incumbent"):
            assert item[side]["pasted"]
    assert "Promotable:  no" in out
    print(json.dumps({"training": training, "timings": result["timings"], "summary": report["summary"]}))

    # Too few test thoughts to promote.
    assert cli.main(["promote", model_id, "--db", str(app_db), "--models-dir", str(models_dir), "--wait", "0",
                     "--vocabulary", str(no_vocabulary)]) == 1
    assert "promotion needs 100" in capsys.readouterr().err
