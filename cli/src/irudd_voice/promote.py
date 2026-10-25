"""`irudd-voice promote`, `rollback` and `spot-check`.

`promote <model>` makes a trained model the active one, only when its
eval-compare report still matches the models, dataset, test set, prompt,
hard checks, judge prompt and vocabulary (compare.binding) and passes the
rule (compare.decide). `promote` and `rollback` change the `active_model`
row in one transaction, so a run killed halfway leaves the old model
active. The app loads the new model at its next idle moment and says so in
`cleanup.loaded_model` (shared/app-state.md).

`spot-check` shows you random pairs the judge decided, without saying which
model wrote which, and reports how often you agreed with it. It never
blocks promotion.
"""

from __future__ import annotations

import argparse
import json
import random
import time
from pathlib import Path

from . import appstate, compare, db, judge, models, vocab
from . import prompt as cleanup_prompt
from .label import now_iso
from .model_commands import reports_errors
from .models import DEFAULT_MODELS_DIR, ModelError

WAIT_SECONDS = 15

STALE_REASONS = {
    "candidate": "the candidate's folder changed",
    "incumbent": "the incumbent changed",
    "dataset_hash": "the candidate's training dataset differs from the one in the report",
    "test_set_sha256": "the frozen test thoughts changed",
    "prompt_version": "the cleanup prompt changed",
    "prompt_sha256": "the cleanup prompt changed",
    "hardchecks_sha256": "the hard checks changed",
    "judge_prompt_version": "the judge prompt changed",
    "judge_prompt_sha256": "the judge prompt changed",
    "vocabulary_sha256": "the vocabulary changed",
}


def stale_reasons(report: dict, current: dict) -> list[str]:
    """Why a report no longer applies, [] when it does."""
    reasons = []
    for key, value in current.items():
        if report.get(key) != value:
            reason = STALE_REASONS.get(key, f"{key} changed")
            if key == "incumbent" and report.get(key, {}).get("id") != value["id"]:
                reason = (f"the report compares with {report.get(key, {}).get('id')}, but the active model is "
                          f"{value['id']}")
            if reason not in reasons:
                reasons.append(reason)
    return reasons


def log_event(con, message: str) -> None:
    """A line in the app's log (`irudd-voice events`), in the same
    transaction as the change it describes."""
    con.execute("INSERT INTO events (at, level, category, message) VALUES (?, 'info', 'model', ?)",
                (now_iso(), message))


def set_active(con, model_id: str | None, previous: str | None) -> None:
    con.execute(
        "INSERT INTO active_model (slot, model_id, previous_model_id, changed_at) VALUES (1, ?, ?, ?) "
        "ON CONFLICT (slot) DO UPDATE SET model_id = excluded.model_id, "
        "previous_model_id = excluded.previous_model_id, changed_at = excluded.changed_at",
        (model_id, previous, now_iso()))


def promote(path: Path, model_id: str, models_dir: Path, terms: list[str]) -> str | None:
    """Makes `model_id` active. Returns the model it replaced (None: the
    default). Raises ModelError with every reason when it refuses."""
    problems = models.verify(models_dir / model_id)
    if problems:
        raise ModelError(f"{model_id} can't be promoted: its folder doesn't verify ({problems[0]})")
    con = db.connect(path, write=True)
    try:
        with db.write_transaction(con):
            row = compare.model_row(con, model_id)
            if row is None:
                raise ModelError(f"{model_id} isn't in the models table")
            report = row["report"]
            if not report or report.get("kind") != compare.REPORT_KIND or report.get("version") != compare.REPORT_VERSION:
                raise ModelError(f"{model_id} has no eval-compare report; run: irudd-voice eval-compare {model_id}")
            if report.get("candidate", {}).get("id") != model_id:
                raise ModelError(f"the report stored with {model_id} is for {report.get('candidate', {}).get('id')}")
            current_id, _ = compare.active(con)
            incumbent = current_id or models.default_model_id()
            if incumbent == model_id:
                raise ModelError(f"{model_id} is already active")
            reasons = stale_reasons(report, compare.binding(con, model_id, incumbent, models_dir, terms))
            if reasons:
                raise ModelError(f"the eval-compare report for {model_id} is stale: " + "; ".join(reasons)
                                 + f". Run it again: irudd-voice eval-compare {model_id}")
            decision = compare.decide(report["items"])
            if not decision["promotable"]:
                raise ModelError(f"{model_id} isn't better than {incumbent}: " + "; ".join(decision["reasons"]))
            set_active(con, model_id, current_id)
            summary = compare.summarize(report["items"])
            log_event(con, f"Promoted {model_id} over {incumbent} (won {summary['votes']['win']} of "
                           f"{summary['decided']} votes on {summary['compared']} test thoughts)")
    finally:
        con.close()
    return current_id


def rollback(path: Path, models_dir: Path) -> tuple[str | None, str | None]:
    """Swaps the active and previous model, so a second rollback undoes the
    first. Returns (now active, was active); None is the default model."""
    con = db.connect(path, write=True)
    try:
        with db.write_transaction(con):
            current_id, previous = compare.active(con)
            if current_id is None and previous is None:
                raise ModelError("nothing to roll back to: the default model is active and there's no previous one")
            if previous is not None and not (models_dir / previous).is_dir():
                raise ModelError(f"can't roll back to {previous}: {models_dir / previous} is gone")
            set_active(con, previous, current_id)
            log_event(con, f"Rolled back from {current_id or models.default_model_id()} to "
                           f"{previous or models.default_model_id()}")
    finally:
        con.close()
    return previous, current_id


def report_loaded(path: Path, model_id: str, wait: float, sleep=time.sleep, clock=time.monotonic) -> bool:
    """Waits up to `wait` seconds for the app to load `model_id`, and says
    whether it did."""
    deadline = clock() + wait
    while True:
        loaded = appstate.loaded_model(path)
        if loaded == model_id:
            print(f"The app has loaded {model_id}.")
            return True
        if clock() >= deadline:
            break
        sleep(1)
    con = db.connect(path)
    try:
        status = appstate.read(con, appstate.STATUS)
    finally:
        con.close()
    if status is None:
        print(f"The app hasn't reported a loaded model (it may not be running); it loads {model_id} when it starts.")
    else:
        print(f"The app hasn't loaded {model_id} yet (status: {status}, loaded: {loaded or 'nothing'}). "
              "It switches at its next idle moment; check with: irudd-voice models status")
    return False


def database(args) -> Path:
    return getattr(args, "db", None) or db.DEFAULT_PATH


def promote_command(args) -> int:
    path = database(args)
    terms = vocab.load_terms(args.vocabulary)[: cleanup_prompt.load()["vocabulary_limit"]]
    replaced = promote(path, args.model, args.models_dir, terms)
    print(f"Promoted {args.model} (was {replaced or models.default_model_id() + ', the default'}). "
          "Undo with: irudd-voice rollback")
    report_loaded(path, args.model, args.wait)
    return 0


def rollback_command(args) -> int:
    path = database(args)
    now, was = rollback(path, args.models_dir)
    now_id = now or models.default_model_id()
    print(f"Rolled back: {now_id}{' (the default)' if now is None else ''} is active again, replacing {was or models.default_model_id()}.")
    report_loaded(path, now_id, args.wait)
    return 0


def status_command(args) -> int:
    """What Settings → Model shows, for the terminal."""
    path = database(args)
    con = db.connect(path)
    try:
        current_id, previous = compare.active(con)
        active_id = current_id or models.default_model_id()
        row = compare.model_row(con, active_id)
        loaded, status = appstate.read(con, appstate.LOADED_MODEL), appstate.read(con, appstate.STATUS)
    finally:
        con.close()
    print(f"Active:   {active_id}{' (default)' if current_id is None else ''}")
    if row and row["trained_at"]:
        print(f"Trained:  {row['trained_at']} on {row['trained_chunks']} thoughts")
    if row and row["report"]:
        s = row["report"]["summary"]
        rate = f"{100 * s['win_rate']:.0f}%" if s["win_rate"] is not None else "n/a"
        print(f"Score:    won {s['votes']['win']} of {s['decided']} votes ({rate}) against "
              f"{row['report']['incumbent']['id']} on {s['compared']} test thoughts")
    print(f"Previous: {previous or ('none' if current_id is None else models.default_model_id() + ' (default)')}")
    print(f"App:      {status or 'no status yet'}{f', loaded {loaded}' if loaded else ''}")
    return 0


def read_report(source: str, path: Path) -> tuple[dict, str | None]:
    """(report, model ID) from a model ID's row or a report file."""
    file = Path(source)
    if file.suffix == ".json" and file.exists():
        return json.loads(file.read_text()), None
    con = db.connect(path)
    try:
        row = compare.model_row(con, source)
    finally:
        con.close()
    if row is None or not row["report"]:
        raise ModelError(f"no eval-compare report for {source}; run: irudd-voice eval-compare {source}")
    return row["report"], source


def spot_check(report: dict, transcripts: dict[int, str], pairs: int, rng: random.Random, ask=input,
               out=print) -> dict:
    """Shows up to `pairs` decided pairs in random A/B order and counts how
    often the answer matches the judge."""
    decided = [item for item in report["items"]
               if item["vote"] in judge.DECIDED and item["chunk_id"] in transcripts]
    if not decided:
        raise ModelError("the report has no decided votes to check")
    if len(decided) < pairs:
        out(f"Only {len(decided)} decided pairs; showing all of them.")
    chosen = rng.sample(decided, min(pairs, len(decided)))
    agreed = answered = 0
    for n, item in enumerate(chosen, 1):
        sides = ["candidate", "incumbent"]
        rng.shuffle(sides)
        out(f"\n[{n}/{len(chosen)}] What was said:\n  {transcripts[item['chunk_id']]}")
        for letter, side in zip("AB", sides, strict=True):
            out(f"{letter}: {item[side]['pasted']}")
        while True:
            try:
                answer = ask("Which is better? a, b, s to skip, q to stop: ").strip().lower()
            except EOFError:
                answer = "q"
            if answer in ("a", "b", "s", "q"):
                break
        if answer == "q":
            break
        if answer == "s":
            continue
        answered += 1
        pick = sides[0] if answer == "a" else sides[1]
        agreed += pick == ("candidate" if item["vote"] == judge.WIN else "incumbent")
    result = {"answered": answered, "agreed": agreed,
              "agreement": round(agreed / answered, 4) if answered else None, "at": now_iso()}
    if answered:
        out(f"\nYou agreed with the judge on {agreed} of {answered} pairs ({100 * agreed / answered:.0f}%).")
    else:
        out("\nNo pairs answered.")
    return result


def spot_check_command(args) -> int:
    path = database(args)
    report, model_id = read_report(args.report, path)
    con = db.connect(path)
    try:
        ids = [item["chunk_id"] for item in report["items"]]
        transcripts = dict(con.execute(
            f"SELECT id, raw_text FROM chunks WHERE id IN ({','.join('?' * len(ids))})", ids).fetchall())
    finally:
        con.close()
    result = spot_check(report, transcripts, args.pairs, random.Random(args.seed))
    if model_id and result["answered"]:
        report["spot_check"] = result
        compare.store(path, model_id, report)
    return 0


def register(commands) -> None:
    db_help = "database file (default: the app's)"
    dir_help = "where model folders are (default: the app's)"
    wait_help = f"seconds to wait for the app to load it (default {WAIT_SECONDS})"
    parser = commands.add_parser("promote", help="make a trained model active if its eval-compare report allows it")
    parser.add_argument("model", help="model ID")
    parser.add_argument("--models-dir", type=Path, default=DEFAULT_MODELS_DIR, help=dir_help)
    parser.add_argument("--vocabulary", type=Path, default=vocab.DEFAULT_PATH,
                        help=f"vocabulary file, as given to eval-compare (default: {vocab.DEFAULT_PATH})")
    parser.add_argument("--db", type=Path, default=argparse.SUPPRESS, help=db_help)
    parser.add_argument("--wait", type=float, default=WAIT_SECONDS, help=wait_help)
    parser.set_defaults(run=reports_errors(promote_command))

    parser = commands.add_parser("rollback", help="make the previous model active again")
    parser.add_argument("--models-dir", type=Path, default=DEFAULT_MODELS_DIR, help=dir_help)
    parser.add_argument("--db", type=Path, default=argparse.SUPPRESS, help=db_help)
    parser.add_argument("--wait", type=float, default=WAIT_SECONDS, help=wait_help)
    parser.set_defaults(run=reports_errors(rollback_command))

    parser = commands.add_parser("spot-check", help="judge 10 random pairs yourself and see if you agree")
    parser.add_argument("report", help="model ID (its stored report) or a report file from eval-compare --out")
    parser.add_argument("--pairs", type=int, default=10, help="how many pairs (default 10)")
    parser.add_argument("--seed", type=int, help="random seed (default: different each time)")
    parser.add_argument("--db", type=Path, default=argparse.SUPPRESS, help=db_help)
    parser.set_defaults(run=reports_errors(spot_check_command))
