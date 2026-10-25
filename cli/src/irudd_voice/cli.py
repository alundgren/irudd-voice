"""irudd-voice command line."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from statistics import median

from . import db


def stats(con, path: Path) -> dict:
    by_status = dict(con.execute("SELECT status, COUNT(*) FROM chunks GROUP BY status").fetchall())
    total_ms, first_day, last_day, days = con.execute(
        "SELECT COALESCE(SUM(duration_ms), 0), MIN(local_day), MAX(local_day), COUNT(DISTINCT local_day) FROM chunks"
    ).fetchone()
    labels = dict(con.execute("SELECT status, COUNT(*) FROM labels GROUP BY status").fetchall())
    # Seconds from the end of a thought (the mute press) to its audio being
    # saved and to its text being ready, over the last 20 transcribed thoughts.
    timings = con.execute(
        "SELECT (julianday(created_at) - julianday(ended_at)) * 86400, "
        "(julianday(transcribed_at) - julianday(ended_at)) * 86400 "
        "FROM chunks WHERE status = 'transcribed' ORDER BY id DESC LIMIT 20"
    ).fetchall()
    last = con.execute(
        "SELECT ended_at, status, raw_text FROM chunks ORDER BY id DESC LIMIT 1"
    ).fetchone()
    return {
        "database": str(path),
        "size_bytes": db.size_on_disk(path),
        "schema_version": con.execute("PRAGMA user_version").fetchone()[0],
        "thoughts": sum(by_status.values()),
        "by_status": {s: by_status.get(s, 0) for s in ("transcribed", "pending", "error", "discarded")},
        "audio_seconds": round(total_ms / 1000, 1),
        "days": days,
        "first_day": first_day,
        "last_day": last_day,
        "labels": {s: labels.get(s, 0) for s in ("accepted", "rejected")},
        "speed": None if not timings else {
            "thoughts": len(timings),
            "saved_after_seconds": round(median(t[0] for t in timings), 2),
            "text_after_seconds": round(median(t[1] for t in timings), 2),
            "slowest_text_after_seconds": round(max(t[1] for t in timings), 2),
        },
        "last_thought": None if last is None else {"ended_at": last[0], "status": last[1], "text": last[2]},
    }


def human_size(n: int) -> str:
    for unit in ("bytes", "KB", "MB", "GB"):
        if n < 1000 or unit == "GB":
            return f"{n:.0f} {unit}" if unit == "bytes" else f"{n:.1f} {unit}"
        n /= 1000
    return f"{n:.1f} GB"


def human_duration(seconds: float) -> str:
    minutes, secs = divmod(int(round(seconds)), 60)
    hours, minutes = divmod(minutes, 60)
    if hours:
        return f"{hours} h {minutes} min"
    if minutes:
        return f"{minutes} min {secs} s"
    return f"{secs} s"


def print_stats(s: dict) -> None:
    st = s["by_status"]
    print(f"Database:  {s['database']}")
    print(f"           {human_size(s['size_bytes'])}, schema version {s['schema_version']}")
    print(f"Thoughts:  {s['thoughts']} ({st['transcribed']} transcribed, {st['pending']} pending, "
          f"{st['error']} failed, {st['discarded']} thrown away)")
    if s["thoughts"]:
        span = s["first_day"] if s["days"] == 1 else f"{s['first_day']} to {s['last_day']}"
        print(f"Audio:     {human_duration(s['audio_seconds'])} over {s['days']} day(s) ({span})")
    print(f"Labels:    {s['labels']['accepted']} accepted, {s['labels']['rejected']} rejected")
    if s["speed"]:
        sp = s["speed"]
        print(f"Speed:     audio saved {sp['saved_after_seconds']} s and text ready {sp['text_after_seconds']} s "
              f"after you stop (median of last {sp['thoughts']}; slowest {sp['slowest_text_after_seconds']} s)")
    if s["last_thought"]:
        text = s["last_thought"]["text"] or f"({s['last_thought']['status']})"
        if len(text) > 70:
            text = text[:67] + "…"
        print(f"Last:      {s['last_thought']['ended_at']}  {text}")


def models_command(args) -> int:
    from . import models

    if args.models_command == "verify":
        problems = models.verify(args.dir)
        for problem in problems:
            print(f"{args.dir.name}: {problem}", file=sys.stderr)
        if not problems:
            print(f"{args.dir.name}: manifest and checksums OK")
        return 1 if problems else 0
    cand = models.candidate(args.candidate)
    folder, manifest = models.prepare(cand, args.models_dir, force=args.force)
    if args.db:
        models.record(args.db, manifest)
        print(f"recorded {manifest['id']} in {args.db}")
    print(folder)
    return 0


def add_ml_commands(commands) -> None:
    from .models import DEFAULT_MODELS_DIR

    models_parser = commands.add_parser("models", help="prepare and check model folders (needs --group ml)")
    models_commands = models_parser.add_subparsers(dest="models_command", required=True)
    prepare = models_commands.add_parser("prepare", help="convert a pinned base model to a 4-bit model folder")
    prepare.add_argument("candidate", help="qwen3.5-2b, gemma-4-e2b or qwen3.5-4b")
    prepare.add_argument("--models-dir", type=Path, default=DEFAULT_MODELS_DIR,
                         help="where model folders go (default: the app's)")
    prepare.add_argument("--db", type=Path, default=argparse.SUPPRESS,
                         help="also insert or update the model's row in this database")
    prepare.add_argument("--force", action="store_true", help="rebuild even if the folder is already there")
    verify = models_commands.add_parser("verify", help="check a model folder's manifest and checksums")
    verify.add_argument("dir", type=Path)

    train = commands.add_parser("train", help="fine-tune a candidate with LoRA (needs --group ml)")
    train.add_argument("candidate", help="qwen3.5-2b, gemma-4-e2b or qwen3.5-4b")
    train.add_argument("--tiny", action="store_true",
                       help="40 synthetic examples, to check the training round trip")
    train.add_argument("--models-dir", type=Path, default=DEFAULT_MODELS_DIR,
                       help="where model folders go (default: the app's)")

    evaluate = commands.add_parser("eval", help="run a model over the fixed eval sets (needs --group ml)")
    evaluate.add_argument("dir", type=Path, help="model folder")
    evaluate.add_argument("--set", choices=("questions", "transcripts", "all"), default="all")
    evaluate.add_argument("--out", type=Path, help="write the full JSON report here (default: print it)")

    from .parity import DEFAULT_INPUTS

    parity = commands.add_parser("parity-reference", help="greedy token IDs for the Swift parity check (needs --group ml)")
    parity.add_argument("dir", type=Path, help="model folder")
    parity.add_argument("--out", type=Path, required=True, help="JSON file to write")
    parity.add_argument("--inputs", type=Path, default=DEFAULT_INPUTS, help="inputs (default: evals/parity.jsonl)")


def parity_command(args) -> int:
    from . import parity

    result = parity.reference(args.dir, args.inputs, log=lambda line: print(line, file=sys.stderr))
    parity.write(result, args.out)
    print(args.out)
    return 0


def train_command(args) -> int:
    from . import models, train

    if not args.tiny:
        print("irudd-voice: only `train --tiny <candidate>` exists so far; training on labeled thoughts comes "
              "with the dataset tools", file=sys.stderr)
        return 2
    result = train.train_tiny(models.candidate(args.candidate), args.models_dir)
    print(json.dumps({"folder": str(result.folder), "timings": result.timings,
                      "training": result.manifest["training"]}, indent=2))
    return 0


def eval_command(args) -> int:
    from . import evaluate

    sets = list(evaluate.SETS) if args.set == "all" else [args.set]
    report = evaluate.evaluate_folder(args.dir, sets, log=lambda line: print(line, file=sys.stderr))
    text = json.dumps(report, indent=1, ensure_ascii=False) + "\n"
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(text)
    summary = {name: s["summary"] for name, s in report["sets"].items()}
    print(json.dumps({"model_id": report["model_id"], "summary": summary,
                      "hard_check_gate": report["hard_check_gate"]}, indent=2) if args.out else text, end="\n")
    return 0


ML_COMMANDS = {"eval": eval_command, "train": train_command, "models": models_command, "parity-reference": parity_command}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="irudd-voice", description=__doc__)
    parser.add_argument("--db", type=Path, default=None, help="database file (default: the app's)")
    commands = parser.add_subparsers(dest="command", required=True)
    stats_parser = commands.add_parser("stats", help="what's been recorded so far")
    stats_parser.add_argument("--json", action="store_true", help="print JSON")
    events_parser = commands.add_parser("events", help="the app's recent log lines")
    events_parser.add_argument("-n", type=int, default=40, help="how many (default 40)")
    add_ml_commands(commands)
    args = parser.parse_args(argv)

    if args.command in ML_COMMANDS:
        from .models import ModelError

        try:
            return ML_COMMANDS[args.command](args)
        except (ModelError, db.SchemaError) as error:
            print(f"irudd-voice: {error}", file=sys.stderr)
            return 1

    path = args.db or db.DEFAULT_PATH
    try:
        con = db.connect(path)
    except db.SchemaError as error:
        print(f"irudd-voice: {error}", file=sys.stderr)
        return 1

    with con:
        if args.command == "events":
            rows = con.execute(
                "SELECT at, level, category, chunk_id, message FROM events ORDER BY id DESC LIMIT ?", (args.n,)
            ).fetchall()
            for at, level, category, chunk_id, message in reversed(rows):
                chunk = f" #{chunk_id}" if chunk_id else ""
                print(f"{at}  {level:<7} {category:<8}{chunk}  {message}")
        elif args.command == "stats":
            result = stats(con, path)
            if args.json:
                print(json.dumps(result, indent=2))
            else:
                print_stats(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
