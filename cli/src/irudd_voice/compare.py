"""`irudd-voice eval-compare`: a trained candidate against the incumbent on
the frozen test thoughts.

Both models clean every test thought (chunks on test days with a frozen
accepted label) through the shared prompt, reply parser and hard checks,
exactly as the app would: long thoughts in pieces (pieces.py), each piece
within the prompt's deadline. The report has, per thought: each model's hard
check failures, how close what it would paste is to the label, and a blind
vote by the teacher CLI (judge.py). The report is bound to both models'
manifests, the candidate's dataset, the frozen test set and the prompt,
hard-check and judge-prompt hashes, so `promote` can refuse a stale one.
It's stored in the candidate's `models` row (eval_report_json), and holds
model outputs, so it's never written into the repo.
"""

from __future__ import annotations

import argparse
import gc
import hashlib
import json
import shutil
import sys
from collections import Counter
from collections.abc import Callable
from pathlib import Path
from statistics import mean

from . import appstate, db, evaluate, judge, teacher, vocab
from . import prompt as cleanup_prompt
from .generation import contract_hashes
from .model_commands import reports_errors
from .models import DEFAULT_MODELS_DIR, ModelError, default_model_id, utc_now

REPORT_KIND = "eval-compare"
# 2: thoughts are cleaned in pieces within the prompt's deadline, as in the app.
REPORT_VERSION = 2
# The promotion rule (plan check promote-only-better).
MIN_COMPARED = 100
MIN_WIN_PERCENT = 55
# A judge that fails this many votes in a row is probably logged out or
# offline; stop instead of trying every thought.
MAX_FAILED_IN_A_ROW = 3


def active(con) -> tuple[str | None, str | None]:
    """(model_id, previous_model_id) from active_model; None means the
    app's default base model."""
    row = con.execute("SELECT model_id, previous_model_id FROM active_model WHERE slot = 1").fetchone()
    return (row[0], row[1]) if row else (None, None)


def incumbent_id(con) -> str:
    return active(con)[0] or default_model_id()


def test_thoughts(con) -> list[tuple[int, str, str]]:
    """(chunk_id, raw_text, label) for every transcribed chunk on a test day
    with a frozen accepted label (its first one, as in dataset build)."""
    return con.execute(
        "SELECT c.id, c.raw_text, l.text FROM chunks c "
        "JOIN dataset_days d ON d.local_day = c.local_day AND d.split = 'test' "
        "JOIN labels l ON l.id = (SELECT MIN(id) FROM labels WHERE chunk_id = c.id AND status = 'accepted') "
        "WHERE c.status = 'transcribed' AND TRIM(COALESCE(c.raw_text, '')) != '' AND l.frozen = 1 "
        "ORDER BY c.id").fetchall()


def test_set_sha256(thoughts: list[tuple[int, str, str]]) -> str:
    digest = hashlib.sha256()
    for row in thoughts:
        digest.update(json.dumps(row, ensure_ascii=False).encode() + b"\n")
    return digest.hexdigest()


def manifest_sha256(folder: Path) -> str:
    path = folder / "manifest.json"
    if not path.exists():
        raise ModelError(f"{folder} has no manifest.json")
    return hashlib.sha256(path.read_bytes()).hexdigest()


def model_row(con, model_id: str) -> dict | None:
    row = con.execute("SELECT manifest_json, eval_report_json, trained_at, trained_chunks FROM models WHERE id = ?",
                      (model_id,)).fetchone()
    if row is None:
        return None
    return {"manifest": json.loads(row[0]), "report": json.loads(row[1]) if row[1] else None,
            "trained_at": row[2], "trained_chunks": row[3]}


def load_generator(folder: Path) -> evaluate.Generator:
    """A warm model that cleans like the app does, stopping a piece at the
    prompt's deadline."""
    from .generation import Model

    model = Model(folder)
    model.clean("warm up")  # the first call compiles kernels
    deadline = model.prompt["generation"]["timeout_seconds"]

    def generate(transcript: str, terms: list[str]) -> evaluate.Output:
        gen = model.clean(transcript, terms, deadline_seconds=deadline)
        return evaluate.Output(gen.text, gen.hit_limit, gen.seconds, gen.timed_out)

    return generate


def run_model(folder: Path, thoughts: list[tuple[int, str, str]], terms: list[str], log=print) -> list[dict]:
    """Each thought through one model: hard checks and what the app would
    paste (the raw transcript when anything fails)."""
    generate = load_generator(folder)
    prompt = cleanup_prompt.load()
    results = []
    for chunk_id, transcript, label in thoughts:
        item = {"id": chunk_id, "transcript": transcript, "vocabulary": terms, "expected": label}
        scored = evaluate.score_thought(item, generate, prompt)
        results.append({**scored, "similarity": round(evaluate.similarity(scored["pasted"], label), 4)})
        log(f"{folder.name} #{chunk_id}: {','.join(scored['failures']) or 'ok'}")
    del generate
    gc.collect()  # let MLX free this model before the next one loads
    return results


def compare_items(thoughts, candidate: list[dict], incumbent: list[dict], vote_fn: Callable[..., judge.Vote],
                  log=print) -> list[dict]:
    """Per-thought comparison, with the judge's vote on what each model
    would paste. `vote_fn(transcript, candidate_text, incumbent_text)`."""
    items = []
    failed_in_a_row = 0
    for (chunk_id, transcript, _), cand, inc in zip(thoughts, candidate, incumbent, strict=True):
        vote = vote_fn(transcript, cand["pasted"], inc["pasted"])
        if vote.outcome == judge.FAILED and vote.failure in teacher.CALL_FAILURES:
            failed_in_a_row += 1
            if failed_in_a_row == MAX_FAILED_IN_A_ROW:
                raise ModelError(f"the judge failed {failed_in_a_row} votes in a row ({vote.failure}); "
                                 "check that the teacher CLI works and is logged in. Nothing was stored.")
        else:
            failed_in_a_row = 0
        items.append({
            "chunk_id": chunk_id,
            "candidate": cand,
            "incumbent": inc,
            "new_failures": sorted(set(cand["failures"]) - set(inc["failures"])),
            "vote": vote.outcome,
            "picks": vote.picks,
            "judge_model": vote.model,
            "judge_cost_usd": vote.cost_usd,
        })
        log(f"#{chunk_id}: {vote.outcome}")
    return items


def summarize(items: list[dict]) -> dict:
    votes = Counter(item["vote"] for item in items)
    decided = votes[judge.WIN] + votes[judge.LOSS]
    new_failures = Counter(check for item in items for check in item["new_failures"])
    return {
        # Thoughts with a usable vote; failed judge calls don't count.
        "compared": len(items) - votes[judge.FAILED],
        "thoughts": len(items),
        "votes": {outcome: votes[outcome] for outcome in
                  (judge.WIN, judge.LOSS, judge.TIE, judge.SAME, judge.SPLIT, judge.FAILED)},
        "decided": decided,
        "win_rate": round(votes[judge.WIN] / decided, 4) if decided else None,
        "hard_checks": {
            "candidate_thoughts_failed": sum(bool(item["candidate"]["failures"]) for item in items),
            "incumbent_thoughts_failed": sum(bool(item["incumbent"]["failures"]) for item in items),
            "new_failures": sum(new_failures.values()),
            "new_failures_by_check": dict(sorted(new_failures.items())),
        },
        "closeness": {
            side: round(mean(item[side]["similarity"] for item in items), 4) if items else None
            for side in ("candidate", "incumbent")
        },
        "judge_cost_usd": round(sum(item["judge_cost_usd"] or 0 for item in items), 4),
    }


def decide(items: list[dict]) -> dict:
    """The promotion rule, from the per-thought results: at least
    MIN_COMPARED thoughts compared with a usable vote, at least MIN_WIN_PERCENT of the decided
    votes won (ties, identical outputs, order disagreements and failed
    calls don't count), and no hard check the candidate fails on a thought
    where the incumbent passed it."""
    summary = summarize(items)
    wins, decided = summary["votes"][judge.WIN], summary["decided"]
    reasons = []
    if summary["compared"] < MIN_COMPARED:
        reasons.append(f"only {summary['compared']} test thoughts compared with a usable vote; "
                       f"promotion needs {MIN_COMPARED}")
    if decided == 0:
        reasons.append("no decided votes")
    elif wins * 100 < MIN_WIN_PERCENT * decided:
        reasons.append(f"won {wins} of {decided} decided votes ({100 * wins / decided:.1f}%); "
                       f"promotion needs {MIN_WIN_PERCENT}%")
    if summary["hard_checks"]["new_failures"]:
        by_check = ", ".join(f"{check} {n}" for check, n in summary["hard_checks"]["new_failures_by_check"].items())
        reasons.append(f"fails hard checks the incumbent passed ({by_check})")
    return {"promotable": not reasons, "reasons": reasons,
            "rule": {"min_compared": MIN_COMPARED, "min_win_percent": MIN_WIN_PERCENT, "new_failures": 0}}


def binding(con, candidate_id: str, incumbent: str, models_dir: Path, terms: list[str]) -> dict:
    """What a report is valid for. `promote` rebuilds this and refuses a
    report whose binding differs."""
    cand_folder, inc_folder = models_dir / candidate_id, models_dir / incumbent
    row = model_row(con, candidate_id)
    if row is None:
        raise ModelError(f"{candidate_id} isn't in the models table; record it with: "
                         f"irudd-voice models register {cand_folder}")
    training = row["manifest"].get("training") or {}
    return {
        "candidate": {"id": candidate_id, "manifest_sha256": manifest_sha256(cand_folder)},
        "incumbent": {"id": incumbent, "manifest_sha256": manifest_sha256(inc_folder)},
        "dataset_hash": training.get("dataset_hash"),
        "test_set_sha256": test_set_sha256(test_thoughts(con)),
        "prompt_version": cleanup_prompt.load()["version"],
        **contract_hashes(),
        "judge_prompt_version": judge.load()["version"],
        "judge_prompt_sha256": judge.prompt_sha256(),
        "vocabulary_sha256": hashlib.sha256("".join(t + "\n" for t in terms).encode()).hexdigest(),
    }


def report(bind: dict, items: list[dict], teacher_name: str, incumbent_row: dict | None) -> dict:
    """The full report. `summary`, `decision` and `incumbent_summary` are
    what Settings → Model shows (shared/app-state.md, "Eval reports")."""
    return {
        "kind": REPORT_KIND,
        "version": REPORT_VERSION,
        **bind,
        "judge": {"teacher": teacher_name,
                  "model": next((item["judge_model"] for item in items if item["judge_model"]), None)},
        "created_at": utc_now(),
        "summary": summarize(items),
        "decision": decide(items),
        "incumbent_summary": None if incumbent_row is None else {
            "trained_at": incumbent_row["trained_at"], "trained_chunks": incumbent_row["trained_chunks"]},
        "items": items,
    }


def store(path: Path, model_id: str, data: dict) -> None:
    con = db.connect(path, write=True)
    try:
        with db.write_transaction(con):
            con.execute("UPDATE models SET eval_report_json = ? WHERE id = ?",
                        (json.dumps(data, ensure_ascii=False), model_id))
    finally:
        con.close()


def print_summary(data: dict) -> None:
    s, d = data["summary"], data["decision"]
    v = s["votes"]
    print(f"{data['candidate']['id']} vs {data['incumbent']['id']} on {s['thoughts']} frozen test thoughts "
          f"({s['compared']} with a usable vote)")
    print(f"Votes:       {v['win']} won, {v['loss']} lost ({v['tie']} tie, {v['same']} same output, "
          f"{v['split']} order disagreed, {v['failed']} failed)"
          + (f"; win rate {100 * s['win_rate']:.1f}%" if s["win_rate"] is not None else ""))
    hc = s["hard_checks"]
    print(f"Hard checks: candidate failed {hc['candidate_thoughts_failed']}, incumbent "
          f"{hc['incumbent_thoughts_failed']}; new failures {hc['new_failures']}")
    print(f"Closeness:   candidate {s['closeness']['candidate']}, incumbent {s['closeness']['incumbent']} "
          "(1.0 = same as the label)")
    if s["judge_cost_usd"]:
        print(f"Judge cost:  ${s['judge_cost_usd']:.4f}")
    if d["promotable"]:
        print("Promotable:  yes")
    else:
        print("Promotable:  no")
        for reason in d["reasons"]:
            print(f"  - {reason}")


def register(commands) -> None:
    parser = commands.add_parser("eval-compare", help="score a trained model against the active one "
                                                      "(needs --group ml)")
    parser.add_argument("candidate", help="model ID of the candidate (a folder in --models-dir)")
    parser.add_argument("--incumbent", help="model ID to compare with (default: the active model)")
    parser.add_argument("--teacher", choices=teacher.TEACHERS, default="claude",
                        help="the judge; use the CLI that wrote the labels (default claude)")
    parser.add_argument("--model", help="judge model (default: the CLI's own default)")
    parser.add_argument("--models-dir", type=Path, default=DEFAULT_MODELS_DIR,
                        help="where model folders are (default: the app's)")
    parser.add_argument("--vocabulary", type=Path, default=vocab.DEFAULT_PATH,
                        help=f"vocabulary file (default: {vocab.DEFAULT_PATH})")
    parser.add_argument("--db", type=Path, default=argparse.SUPPRESS, help="database file (default: the app's)")
    parser.add_argument("--out", type=Path, help="also write the report here; it contains your text, so keep it "
                                                 "out of the repo")
    parser.set_defaults(run=run)


@reports_errors
def run(args) -> int:
    if shutil.which(args.teacher) is None:
        raise ModelError(f"`{args.teacher}` isn't on PATH, so it can't judge; nothing was loaded")
    log = lambda line: print(line, file=sys.stderr)  # noqa: E731
    path = getattr(args, "db", None) or db.DEFAULT_PATH
    terms = vocab.load_terms(args.vocabulary)[: cleanup_prompt.load()["vocabulary_limit"]]
    con = db.connect(path)
    try:
        incumbent = args.incumbent or incumbent_id(con)
        if incumbent == args.candidate:
            raise ModelError(f"{args.candidate} is the incumbent; compare it with another model (--incumbent)")
        thoughts = test_thoughts(con)
        if not thoughts:
            raise ModelError("no frozen test thoughts yet: label some thoughts, then run irudd-voice dataset build")
        bind = binding(con, args.candidate, incumbent, args.models_dir, terms)
        incumbent_row = model_row(con, incumbent)
    finally:
        con.close()

    log(f"{len(thoughts)} frozen test thoughts")
    with appstate.UnloadLease(path, log=log) as lease:
        log(f"going ahead: {lease.wait_for_app()}")
        candidate = run_model(args.models_dir / args.candidate, thoughts, terms, log)
        incumbent_results = run_model(args.models_dir / incumbent, thoughts, terms, log)

    def vote_fn(transcript: str, cand: str, inc: str) -> judge.Vote:
        return judge.vote(args.teacher, transcript, cand, inc, terms, args.model)

    try:
        items = compare_items(thoughts, candidate, incumbent_results, vote_fn, log)
    except FileNotFoundError as error:
        raise ModelError(str(error)) from None
    data = report(bind, items, args.teacher, incumbent_row)
    store(path, args.candidate, data)
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps(data, indent=1, ensure_ascii=False) + "\n")
    print_summary(data)
    print(f"Report stored with {args.candidate} in {path}")
    return 0
