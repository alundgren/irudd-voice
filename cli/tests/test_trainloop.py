"""train, eval-compare, promote, rollback and spot-check on a synthetic
database, with a fake trainer, fake models and a fake judge."""

import json
import os
import random
import signal
import subprocess
import sys
from datetime import UTC, date, datetime

import pytest
from labeling import add_chunk, add_label, rows
from trainloop import FakeJudge, add_test_thought, items, model_folder

from irudd_voice import appstate, cli, compare, db, model_commands, models, promote, train

CANDIDATE = "gemma-4-e2b-ft-20261025-1"
SECOND = "gemma-4-e2b-ft-20261026-1"
BASE = "gemma-4-e2b-base-q4"


@pytest.fixture
def models_dir(tmp_path):
    return tmp_path / "models"


@pytest.fixture
def no_vocabulary(tmp_path):
    return tmp_path / "no-vocabulary.json"


def lease_value(path):
    return dict(rows(path, "SELECT key, value FROM app_state")).get(appstate.UNLOAD_UNTIL)


def active_row(path):
    return rows(path, "SELECT model_id, previous_model_id FROM active_model")


# --- train -------------------------------------------------------------------


@pytest.fixture
def dataset_dir(tmp_path):
    folder = tmp_path / "dataset"
    folder.mkdir()
    (folder / "dataset.json").write_text(json.dumps({
        "dataset_hash": "dataset-1", "prompt_version": "cleanup-v1",
        "examples": {"train": 30, "selection": 4, "test": 5}, "augmented": {"train": 0}}))
    return folder


@pytest.fixture
def fake_trainer(monkeypatch, app_db, models_dir):
    """Replaces train.train_dataset; records what it saw, including whether
    the lease was held while it ran."""
    seen = []
    priority = []
    monkeypatch.setattr(model_commands, "lower_priority", lambda log: priority.append(True))

    def fake(cand, data, model_id, *, models_dir, settings, log):
        seen.append({"candidate": cand.id, "data": data, "model_id": model_id, "lease": lease_value(app_db),
                     "iterations": settings.iterations, "priority_lowered": bool(priority)})
        if getattr(fake, "fail", False):
            raise models.ModelError("out of memory")
        manifest = model_folder(models_dir, model_id, cand.id)
        return train.TrainResult(models_dir / model_id, manifest, {"train_seconds": 1.0})

    monkeypatch.setattr(train, "train_dataset", fake)
    fake.seen = seen
    return fake


def run_train(app_db, models_dir, *extra):
    return cli.main(["train", "--db", str(app_db), "--models-dir", str(models_dir), *extra])


def test_train_holds_the_lease_records_the_model_and_releases(app_db, models_dir, dataset_dir, fake_trainer,
                                                              capsys):
    assert run_train(app_db, models_dir, "--dataset", str(dataset_dir)) == 0
    seen = fake_trainer.seen[0]
    today = date.today().strftime("%Y%m%d")
    assert seen["model_id"] == f"gemma-4-e2b-ft-{today}-1"  # the default candidate
    assert seen["candidate"] == "gemma-4-e2b"
    assert seen["lease"] is not None and seen["priority_lowered"]
    assert seen["iterations"] == 100  # 2 × 30 examples, at least 100
    assert lease_value(app_db) is None
    assert rows(app_db, "SELECT id, trained_chunks, dataset_hash FROM models") == [
        (f"gemma-4-e2b-ft-{today}-1", 12, "dataset-1")]
    assert json.loads(capsys.readouterr().out)["model_id"] == f"gemma-4-e2b-ft-{today}-1"

    # The next run of the day gets the next number; --candidate picks the base.
    assert run_train(app_db, models_dir, "--dataset", str(dataset_dir), "--candidate", "qwen3.5-2b",
                     "--iterations", "7") == 0
    assert fake_trainer.seen[1]["model_id"] == f"qwen3.5-2b-ft-{today}-1"
    assert fake_trainer.seen[1]["iterations"] == 7
    assert run_train(app_db, models_dir, "--dataset", str(dataset_dir)) == 0
    assert fake_trainer.seen[2]["model_id"] == f"gemma-4-e2b-ft-{today}-2"


def test_train_defaults_to_the_active_models_candidate(app_db, models_dir, dataset_dir, fake_trainer):
    model_folder(models_dir, "qwen3.5-4b-ft-20261001-1", "qwen3.5-4b", db_path=app_db)
    con = db.connect(app_db, write=True)
    with db.write_transaction(con):
        promote.set_active(con, "qwen3.5-4b-ft-20261001-1", None)
    con.close()
    assert run_train(app_db, models_dir, "--dataset", str(dataset_dir)) == 0
    assert fake_trainer.seen[0]["candidate"] == "qwen3.5-4b"


def test_failed_training_releases_the_lease_and_records_nothing(app_db, models_dir, dataset_dir, fake_trainer,
                                                                capsys):
    fake_trainer.fail = True
    assert run_train(app_db, models_dir, "--dataset", str(dataset_dir)) == 1
    assert fake_trainer.seen[0]["lease"] is not None
    assert lease_value(app_db) is None
    assert rows(app_db, "SELECT id FROM models") == []
    assert "out of memory" in capsys.readouterr().err


def test_train_stops_when_the_running_app_keeps_its_model(app_db, models_dir, dataset_dir, fake_trainer,
                                                          monkeypatch, capsys):
    monkeypatch.setattr(appstate, "CONFIRM_SECONDS", 0.2)
    con = db.connect(app_db, write=True)
    appstate.write(con, appstate.STATUS, "loaded")
    appstate.write(con, appstate.STATUS_AT, appstate.iso(datetime.now(UTC)))
    con.close()
    assert run_train(app_db, models_dir, "--dataset", str(dataset_dir)) == 1
    assert fake_trainer.seen == []
    assert lease_value(app_db) is None
    assert "didn't unload its model" in capsys.readouterr().err


def test_a_dataset_train_builds_itself_is_deleted_afterwards(app_db, models_dir, fake_trainer, no_vocabulary):
    for n, (spoken, cleaned) in enumerate(train.TINY_REQUESTS):
        chunk_id = add_chunk(app_db, spoken, day=f"2026-10-{n // 2 + 1:02d}")
        add_label(app_db, chunk_id, cleaned)
    assert run_train(app_db, models_dir, "--vocabulary", str(no_vocabulary)) == 0
    data = fake_trainer.seen[0]["data"]
    assert data.name.startswith("irudd-voice-dataset-")
    assert not data.exists()


def test_train_needs_train_and_selection_examples(app_db, models_dir, fake_trainer, capsys, no_vocabulary):
    # No --dataset: train builds one, here from an empty database.
    assert run_train(app_db, models_dir, "--vocabulary", str(no_vocabulary)) == 1
    assert "0 training and 0 selection examples" in capsys.readouterr().err
    assert fake_trainer.seen == [] and lease_value(app_db) is None


def test_tiny_still_needs_a_candidate(app_db, models_dir, capsys):
    assert cli.main(["train", "--tiny"]) == 1
    assert "needs a candidate" in capsys.readouterr().err


# --- eval-compare ------------------------------------------------------------


@pytest.fixture
def two_models(app_db, models_dir):
    model_folder(models_dir, BASE, trained=False, db_path=app_db)
    model_folder(models_dir, CANDIDATE, db_path=app_db)


@pytest.fixture
def fake_models(monkeypatch, app_db):
    """compare.load_generator without MLX: outputs[model id][transcript]
    is the cleaned text it replies with; leases seen while generating."""
    outputs: dict[str, dict[str, str]] = {CANDIDATE: {}, BASE: {}}
    leases = []

    def load_generator(folder):
        def generate(transcript, terms):
            from irudd_voice.evaluate import Output

            leases.append(lease_value(app_db))
            text = outputs[folder.name].get(transcript, transcript)
            return Output(json.dumps({"cleaned": text}), False, 0.01)

        return generate

    monkeypatch.setattr(compare, "load_generator", load_generator)
    outputs["leases"] = leases
    return outputs


def test_eval_compare_scores_votes_and_stores_a_bound_report(app_db, models_dir, two_models, fake_models,
                                                            tmp_path, monkeypatch, no_vocabulary, capsys):
    judge = FakeJudge(tmp_path, monkeypatch)
    win = add_test_thought(app_db, "um set the port to eighty", "Set the port to eighty.")
    same = add_test_thought(app_db, "do not delete the cache", "Do not delete the cache.")
    split = add_test_thought(app_db, "make it blue sorry make it green", "Make it green.")
    worse = add_test_thought(app_db, "set the retry count to three", "Set the retry count to three.")
    add_test_thought(app_db, "label canary thought", "LABEL-CANARY-7f3a9 must never reach the judge")
    fake_models[CANDIDATE]["label canary thought"] = "Label canary thought."
    fake_models[CANDIDATE].update({"um set the port to eighty": "Set the port to eighty.",
                                   "do not delete the cache": "Do not delete the cache.",
                                   "make it blue sorry make it green": "Make it green.",
                                   "set the retry count to three": "Set the retry count to four."})
    fake_models[BASE].update({"um set the port to eighty": "Um, set the port to eighty.",
                              "do not delete the cache": "Do not delete the cache.",
                              "make it blue sorry make it green": "Make it blue, sorry, make it green.",
                              "set the retry count to three": "Set the retry count to three."})
    judge.rule("um set the port to eighty", prefer="Set the port to eighty.")
    judge.rule("make it blue sorry make it green", always="A")
    judge.rule("set the retry count to three", prefer="Set the retry count to three.")

    assert cli.main(["eval-compare", CANDIDATE, "--db", str(app_db), "--models-dir", str(models_dir),
                     "--vocabulary", str(no_vocabulary)]) == 0
    out = capsys.readouterr().out
    assert "1 won, 1 lost (1 tie, 1 same output, 1 order disagreed, 0 failed)" in out
    assert "only 5 test thoughts compared with a usable vote; promotion needs 100" in out
    assert all(fake_models["leases"])  # generation ran under the unload lease
    assert lease_value(app_db) is None
    calls = judge.calls()
    assert len(calls) == 8  # identical outputs need no judge
    # Labels never leave: not in any judge's prompt or arguments.
    assert any("label canary thought" in call["stdin"] for call in calls)
    for call in calls:
        assert "LABEL-CANARY" not in call["stdin"] and not any("LABEL-CANARY" in a for a in call["argv"])

    report = json.loads(rows(app_db, "SELECT eval_report_json FROM models WHERE id = ?", (CANDIDATE,))[0][0])
    assert report["candidate"]["id"] == CANDIDATE and report["incumbent"]["id"] == BASE
    assert report["dataset_hash"] == "dataset-1"
    assert report["judge"] == {"teacher": "claude", "model": "claude-fake-judge"}
    by_chunk = {i["chunk_id"]: i for i in report["items"]}
    assert by_chunk[win]["vote"] == "win" and by_chunk[same]["vote"] == "same"
    assert by_chunk[split]["vote"] == "split" and by_chunk[worse]["vote"] == "loss"
    # The candidate's "four" fails the numbers check where the base passed.
    assert by_chunk[worse]["new_failures"] == ["numbers"]
    assert by_chunk[worse]["candidate"]["pasted"] == "set the retry count to three"
    assert report["summary"]["hard_checks"]["new_failures"] == 1
    assert report["decision"]["promotable"] is False
    with db.connect(app_db) as con:
        assert compare.binding(con, CANDIDATE, BASE, models_dir, []) == {
            key: report[key] for key in compare.binding(con, CANDIDATE, BASE, models_dir, [])}


def test_eval_compare_stops_after_three_failed_votes(app_db, models_dir, two_models, fake_models, tmp_path,
                                                    monkeypatch, no_vocabulary, capsys):
    judge = FakeJudge(tmp_path, monkeypatch)
    judge.rule("*", exit=1)
    for n in range(5):
        add_test_thought(app_db, f"thought {n}", f"Thought {n}.")
        fake_models[CANDIDATE][f"thought {n}"] = f"Thought {n}."
    assert cli.main(["eval-compare", CANDIDATE, "--db", str(app_db), "--models-dir", str(models_dir),
                     "--vocabulary", str(no_vocabulary)]) == 1
    assert "failed 3 votes in a row" in capsys.readouterr().err
    assert rows(app_db, "SELECT eval_report_json FROM models WHERE id = ?", (CANDIDATE,)) == [(None,)]


def test_eval_compare_fails_before_loading_when_the_judge_is_missing(app_db, models_dir, two_models, fake_models,
                                                                    tmp_path, monkeypatch, no_vocabulary, capsys):
    add_test_thought(app_db, "thought", "Thought.")
    empty = tmp_path / "empty-bin"
    empty.mkdir()
    monkeypatch.setenv("PATH", str(empty))
    assert cli.main(["eval-compare", CANDIDATE, "--teacher", "codex", "--db", str(app_db), "--models-dir",
                     str(models_dir), "--vocabulary", str(no_vocabulary)]) == 1
    assert "`codex` isn't on PATH" in capsys.readouterr().err
    assert fake_models["leases"] == [] and lease_value(app_db) is None


def test_eval_compare_needs_frozen_test_thoughts(app_db, models_dir, two_models, no_vocabulary, capsys):
    assert cli.main(["eval-compare", CANDIDATE, "--db", str(app_db), "--models-dir", str(models_dir),
                     "--vocabulary", str(no_vocabulary)]) == 1
    assert "no frozen test thoughts" in capsys.readouterr().err


# --- promote and rollback ----------------------------------------------------


def store_report(path, models_dir, candidate, incumbent, rows_=None, terms=()):
    con = db.connect(path)
    bind = compare.binding(con, candidate, incumbent, models_dir, list(terms))
    con.close()
    data = compare.report(bind, rows_ if rows_ is not None else items(win=60, loss=40), "claude", None)
    compare.store(path, candidate, data)
    return data


@pytest.fixture
def ready(app_db, models_dir, two_models):
    """A candidate with a passing report against the default model."""
    add_test_thought(app_db, "um set the port to eighty", "Set the port to eighty.")
    store_report(app_db, models_dir, CANDIDATE, BASE)


def run_promote(app_db, models_dir, model, *extra):
    return cli.main(["promote", model, "--db", str(app_db), "--models-dir", str(models_dir), "--wait", "0",
                     "--vocabulary", str(models_dir / "no-vocabulary.json"), *extra])


def run_rollback(app_db, models_dir):
    return cli.main(["rollback", "--db", str(app_db), "--models-dir", str(models_dir), "--wait", "0"])


def test_promote_then_rollback_and_back(app_db, models_dir, ready, capsys):
    assert run_promote(app_db, models_dir, CANDIDATE) == 0
    assert active_row(app_db) == [(CANDIDATE, None)]
    out = capsys.readouterr().out
    assert f"Promoted {CANDIDATE} (was {BASE}, the default)" in out
    assert "hasn't reported a loaded model" in out
    assert rows(app_db, "SELECT category, message FROM events")[-1] == (
        "model", f"Promoted {CANDIDATE} over {BASE} (won 60 of 100 votes on 100 test thoughts)")

    # A second model replaces the first, which is kept for rollback.
    model_folder(models_dir, SECOND, dataset_hash="dataset-2", db_path=app_db)
    store_report(app_db, models_dir, SECOND, CANDIDATE)
    assert run_promote(app_db, models_dir, SECOND) == 0
    assert active_row(app_db) == [(SECOND, CANDIDATE)]

    assert run_rollback(app_db, models_dir) == 0
    assert active_row(app_db) == [(CANDIDATE, SECOND)]
    assert run_rollback(app_db, models_dir) == 0  # undoes the rollback
    assert active_row(app_db) == [(SECOND, CANDIDATE)]
    assert "Rolled back" in capsys.readouterr().out


def test_rollback_to_the_default(app_db, models_dir, ready, capsys):
    assert run_rollback(app_db, models_dir) == 1
    assert "nothing to roll back to" in capsys.readouterr().err
    assert run_promote(app_db, models_dir, CANDIDATE) == 0
    assert run_rollback(app_db, models_dir) == 0
    assert active_row(app_db) == [(None, CANDIDATE)]
    assert f"{BASE} (the default) is active again" in capsys.readouterr().out


def test_promote_reports_when_the_app_has_loaded_it(app_db, models_dir, ready, capsys):
    con = db.connect(app_db, write=True)
    appstate.write(con, appstate.LOADED_MODEL, CANDIDATE)
    con.close()
    assert run_promote(app_db, models_dir, CANDIDATE) == 0
    assert f"The app has loaded {CANDIDATE}." in capsys.readouterr().out


def test_promote_says_the_app_hasnt_switched_yet(app_db, models_dir, ready, capsys):
    con = db.connect(app_db, write=True)
    appstate.write(con, appstate.LOADED_MODEL, BASE)
    appstate.write(con, appstate.STATUS, "loaded")
    con.close()
    assert run_promote(app_db, models_dir, CANDIDATE) == 0
    assert f"hasn't loaded {CANDIDATE} yet (status: loaded, loaded: {BASE})" in capsys.readouterr().out


def test_promote_mentions_a_failed_load(app_db, models_dir, ready, capsys):
    con = db.connect(app_db, write=True)
    appstate.write(con, appstate.STATUS, "failed: checksum differs")
    con.close()
    assert run_promote(app_db, models_dir, CANDIDATE) == 0
    assert "couldn't load a model (failed: checksum differs)" in capsys.readouterr().out


def refused(app_db, models_dir, capsys, model=CANDIDATE, *extra):
    assert run_promote(app_db, models_dir, model, *extra) == 1
    assert active_row(app_db) == []
    return capsys.readouterr().err


@pytest.mark.parametrize(("counts", "reason"), [
    ({"win": 99}, "only 99 test thoughts compared"),
    ({"win": 54, "loss": 46}, "won 54 of 100 decided votes (54.0%)"),
    ({"tie": 100}, "no decided votes"),
])
def test_promote_refuses_a_model_that_isnt_better(app_db, models_dir, ready, capsys, counts, reason):
    store_report(app_db, models_dir, CANDIDATE, BASE, items(**counts))
    assert reason in refused(app_db, models_dir, capsys)


def test_promote_after_delete_all_asks_for_a_new_report(app_db, models_dir, ready, capsys):
    # What Delete All Recordings leaves (ChunkStore.deleteAllRecordings).
    con = db.connect(app_db, write=True)
    con.execute("UPDATE models SET eval_report_json = json_remove(eval_report_json, '$.items')")
    con.close()
    assert "Delete All Recordings removed them" in refused(app_db, models_dir, capsys)
    assert cli.main(["spot-check", CANDIDATE, "--db", str(app_db)]) == 1
    assert "no pairs left" in capsys.readouterr().err


def test_promote_refuses_without_a_report(app_db, models_dir, two_models, capsys):
    assert "has no eval-compare report" in refused(app_db, models_dir, capsys)


def edit_report(path, change):
    data = json.loads(rows(path, "SELECT eval_report_json FROM models WHERE id = ?", (CANDIDATE,))[0][0])
    change(data)
    compare.store(path, CANDIDATE, data)


def test_stale_reports_are_refused(app_db, models_dir, ready, capsys, monkeypatch, tmp_path):
    # Each change makes the report stale; undo it before the next.
    add_test_thought(app_db, "a new test thought", "A new test thought.", day="2026-10-22")
    assert "the frozen test thoughts changed" in refused(app_db, models_dir, capsys)
    con = db.connect(app_db, write=True)
    con.execute("DELETE FROM chunks WHERE raw_text = 'a new test thought'")
    con.close()

    vocabulary = tmp_path / "vocabulary.json"
    vocabulary.write_text(json.dumps({"version": 1, "generated_at": "x", "terms": ["SQLite"]}))
    assert "the vocabulary changed" in refused(app_db, models_dir, capsys, CANDIDATE, "--vocabulary",
                                               str(vocabulary))

    real = compare.contract_hashes
    monkeypatch.setattr(compare, "contract_hashes", lambda: {**real(), "hardchecks_sha256": "other"})
    assert "the hard checks changed" in refused(app_db, models_dir, capsys)
    monkeypatch.setattr(compare, "contract_hashes", real)

    edit_report(app_db, lambda d: d.update(dataset_hash="dataset-0"))
    assert "training dataset differs" in refused(app_db, models_dir, capsys)
    edit_report(app_db, lambda d: d.update(dataset_hash="dataset-1"))

    edit_report(app_db, lambda d: d["candidate"].update(id=SECOND))
    assert f"is for {SECOND}" in refused(app_db, models_dir, capsys)
    edit_report(app_db, lambda d: d["candidate"].update(id=CANDIDATE))

    # The candidate's folder was rebuilt: it verifies, but it isn't what was scored.
    manifest = models.read_manifest(models_dir / CANDIDATE)
    models.write_manifest(models_dir / CANDIDATE, CANDIDATE, models.candidate("gemma-4-e2b"),
                          prompt_version=manifest["prompt_version"], training=manifest["training"],
                          created_at="2026-10-26T00:00:00Z")
    assert "the candidate's folder changed" in refused(app_db, models_dir, capsys)


def test_promote_refuses_when_another_model_became_active(app_db, models_dir, ready, capsys):
    model_folder(models_dir, SECOND, db_path=app_db)
    con = db.connect(app_db, write=True)
    with db.write_transaction(con):
        promote.set_active(con, SECOND, None)
    con.close()
    assert run_promote(app_db, models_dir, CANDIDATE) == 1
    assert f"the report compares with {BASE}, but the active model is {SECOND}" in capsys.readouterr().err
    assert active_row(app_db) == [(SECOND, None)]


def test_promote_refuses_a_folder_that_doesnt_verify(app_db, models_dir, ready, capsys):
    (models_dir / CANDIDATE / "model.safetensors").write_bytes(b"changed")
    assert "doesn't verify (model.safetensors: checksum differs)" in refused(app_db, models_dir, capsys)


KILL_SCRIPT = """
import os, signal, sys
from pathlib import Path
from irudd_voice import promote

def die(con, message):
    # Killed after active_model was updated, before the commit.
    os.kill(os.getpid(), signal.SIGKILL)

promote.log_event = die
promote.promote(Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3]), [])
"""


@pytest.mark.parametrize("already_promoted", [False, True])
def test_a_promotion_killed_halfway_leaves_the_old_model_active(app_db, models_dir, ready, tmp_path,
                                                                already_promoted):
    target = CANDIDATE
    if already_promoted:
        assert run_promote(app_db, models_dir, CANDIDATE) == 0
        model_folder(models_dir, SECOND, dataset_hash="dataset-2", db_path=app_db)
        store_report(app_db, models_dir, SECOND, CANDIDATE)
        target = SECOND
    before = active_row(app_db)
    script = tmp_path / "kill.py"
    script.write_text(KILL_SCRIPT)
    process = subprocess.run([sys.executable, str(script), str(app_db), target, str(models_dir)], check=False)
    assert process.returncode == -signal.SIGKILL
    assert active_row(app_db) == before
    assert rows(app_db, "PRAGMA integrity_check") == [("ok",)]
    # Nothing is left locked: the promotion works when run again.
    assert run_promote(app_db, models_dir, target) == 0
    assert active_row(app_db)[0][0] == target


def test_models_status_shows_what_settings_shows(app_db, models_dir, ready, capsys):
    assert run_promote(app_db, models_dir, CANDIDATE) == 0
    capsys.readouterr()
    assert cli.main(["models", "status", "--db", str(app_db)]) == 0
    out = capsys.readouterr().out
    assert f"Active:   {CANDIDATE}" in out
    assert "Trained:  2026-10-25T12:00:00Z on 12 thoughts" in out
    assert f"Score:    won 60 of 100 votes (60%) against {BASE} on 100 test thoughts" in out
    assert f"Previous: {BASE} (default)" in out


# --- spot-check --------------------------------------------------------------


class Human:
    """Answers spot-check prompts from the lines printed before them."""

    def __init__(self, choose):
        self.lines = []
        self.choose = choose

    def out(self, line=""):
        self.lines.append(line)

    def ask(self, question):
        a = next(line for line in reversed(self.lines) if line.startswith("A: "))[3:]
        b = next(line for line in reversed(self.lines) if line.startswith("B: "))[3:]
        return self.choose(a, b)


def test_spot_check_reports_agreement_without_naming_models():
    report = {"items": items(win=6, loss=6, same=5)}
    transcripts = {i["chunk_id"]: f"transcript {i['chunk_id']}" for i in report["items"]}
    # This human always picks the candidate's text ("c<n>").
    human = Human(lambda a, b: "a" if a.startswith("c") else "b")
    result = promote.spot_check(report, transcripts, 10, random.Random(1), human.ask, human.out)
    shown = [int(line[4:]) for line in human.lines if line.startswith(("A: c", "B: c"))]
    assert len(shown) == 10 and all(n <= 12 for n in shown)  # only decided pairs
    assert result["answered"] == 10 and result["agreed"] == sum(n <= 6 for n in shown)
    text = "\n".join(human.lines)
    assert "candidate" not in text and "incumbent" not in text
    assert f"You agreed with the judge on {result['agreed']} of 10 pairs" in text


def test_spot_check_skip_and_stop():
    report = {"items": items(win=3)}
    transcripts = {n: "t" for n in (1, 2, 3)}
    answers = iter(["x", "s", "a", "q"])
    human = Human(lambda a, b: next(answers))
    result = promote.spot_check(report, transcripts, 10, random.Random(0), human.ask, human.out)
    assert "Only 3 decided pairs; showing all of them." in human.lines
    assert result["answered"] == 1


def test_spot_check_command_stores_the_result(app_db, models_dir, ready, monkeypatch, capsys):
    monkeypatch.setattr("builtins.input", lambda prompt: "b")
    store_report(app_db, models_dir, CANDIDATE, BASE, items(win=60, loss=40))
    con = db.connect(app_db)
    chunk_id = con.execute("SELECT id FROM chunks").fetchone()[0]
    con.close()
    # Point every item at the one real chunk so transcripts can be shown.
    edit_report(app_db, lambda d: [i.update(chunk_id=chunk_id) for i in d["items"]])
    assert cli.main(["spot-check", CANDIDATE, "--db", str(app_db), "--seed", "3"]) == 0
    assert "um set the port to eighty" in capsys.readouterr().out
    data = json.loads(rows(app_db, "SELECT eval_report_json FROM models WHERE id = ?", (CANDIDATE,))[0][0])
    assert data["spot_check"]["answered"] == 10
    # Spot-checking doesn't make the report stale.
    assert run_promote(app_db, models_dir, CANDIDATE) == 0


def test_low_priority_uses_taskpolicy(monkeypatch):
    calls = []
    monkeypatch.setattr(os, "nice", lambda n: calls.append(("nice", n)))
    monkeypatch.setattr(subprocess, "run", lambda cmd, **kw: calls.append(tuple(cmd)) or
                        subprocess.CompletedProcess(cmd, 0, "", ""))
    model_commands.lower_priority(print)
    assert calls == [("nice", 10), ("taskpolicy", "-b", "-p", str(os.getpid()))]
