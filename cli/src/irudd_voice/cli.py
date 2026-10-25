"""irudd-voice command line."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from . import db


def stats(con, path: Path) -> dict:
    by_status = dict(con.execute("SELECT status, COUNT(*) FROM chunks GROUP BY status").fetchall())
    total_ms, first_day, last_day, days = con.execute(
        "SELECT COALESCE(SUM(duration_ms), 0), MIN(local_day), MAX(local_day), COUNT(DISTINCT local_day) FROM chunks"
    ).fetchone()
    labels = dict(con.execute("SELECT status, COUNT(*) FROM labels GROUP BY status").fetchall())
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
    if s["last_thought"]:
        text = s["last_thought"]["text"] or f"({s['last_thought']['status']})"
        if len(text) > 70:
            text = text[:67] + "…"
        print(f"Last:      {s['last_thought']['ended_at']}  {text}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="irudd-voice", description=__doc__)
    parser.add_argument("--db", type=Path, default=db.DEFAULT_PATH, help="database file (default: the app's)")
    commands = parser.add_subparsers(dest="command", required=True)
    stats_parser = commands.add_parser("stats", help="what's been recorded so far")
    stats_parser.add_argument("--json", action="store_true", help="print JSON")
    args = parser.parse_args(argv)

    try:
        con = db.connect(args.db)
    except db.SchemaError as error:
        print(f"irudd-voice: {error}", file=sys.stderr)
        return 1

    with con:
        if args.command == "stats":
            result = stats(con, args.db)
            if args.json:
                print(json.dumps(result, indent=2))
            else:
                print_stats(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
