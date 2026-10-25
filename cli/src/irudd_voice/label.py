"""`irudd-voice label`: teacher labels for saved thoughts.

Picks transcribed chunks that have no accepted label yet, asks the teacher
(see teacher.py) for each, and stores every answer in `labels`: `accepted`,
or `rejected` with the reason. A label is rejected when the reply is
malformed or empty, the teacher ran a command, or the hard checks fail
(hardchecks.check, the same checks the app runs before pasting). Spoken
corrections pass because the hard checks recognise them.
"""

from __future__ import annotations

import argparse
import shlex
import sys
from collections import Counter
from datetime import UTC, datetime
from pathlib import Path

from . import db, hardchecks, prompt, teacher, vocab

# A teacher that fails this many calls in a row is probably logged out or
# offline; stop instead of trying every thought.
MAX_FAILED_IN_A_ROW = 3


def now_iso() -> str:
    """UTC ISO 8601 with milliseconds, like the app writes."""
    return datetime.now(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def pending_chunks(con, limit: int | None) -> list[tuple[int, str, str]]:
    """(id, raw_text, local_day) of transcribed chunks without an accepted
    label. Chunks never tried come first, then by age."""
    sql = (
        "SELECT c.id, c.raw_text, c.local_day FROM chunks c "
        "WHERE c.status = 'transcribed' AND TRIM(COALESCE(c.raw_text, '')) != '' "
        "AND NOT EXISTS (SELECT 1 FROM labels l WHERE l.chunk_id = c.id AND l.status = 'accepted') "
        "ORDER BY (SELECT COUNT(*) FROM labels l WHERE l.chunk_id = c.id), c.id"
    )
    if limit is not None:
        sql += f" LIMIT {int(limit)}"
    return con.execute(sql).fetchall()


def judge(transcript: str, answer: teacher.Answer, terms: list[str]) -> tuple[str, str | None]:
    """('accepted', None) or ('rejected', reason). Several failing hard
    checks are joined with commas, in hardchecks.CHECK_ORDER."""
    if answer.failure:
        return "rejected", answer.failure
    settings = prompt.load()["checks"]
    failures = hardchecks.check(transcript, answer.cleaned, terms[: prompt.load()["vocabulary_limit"]],
                                settings["max_output_words_ratio"], settings["max_output_words_slack"])
    if failures:
        return "rejected", ",".join(failures)
    return "accepted", None


def store(con, chunk_id: int, day: str, answer: teacher.Answer, status: str, reason: str | None,
          teacher_name: str) -> None:
    with db.write_transaction(con):
        # A label on a test day is frozen from the start (dataset.py).
        frozen = con.execute("SELECT COUNT(*) FROM dataset_days WHERE local_day = ? AND split = 'test'",
                             (day,)).fetchone()[0]
        con.execute(
            "INSERT INTO labels (chunk_id, text, status, reject_reason, teacher, teacher_model, "
            "teacher_prompt_version, cost_usd, input_tokens, output_tokens, frozen, created_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (chunk_id, answer.cleaned, status, reason, teacher_name, answer.model, teacher.load()["version"],
             answer.cost_usd, answer.input_tokens, answer.output_tokens, 1 if frozen else 0, now_iso()),
        )


def register(commands) -> None:
    parser = commands.add_parser("label", help="ask a teacher (Claude Code or Codex) for labels")
    parser.add_argument("--teacher", choices=teacher.TEACHERS, default="claude", help="which CLI (default claude)")
    parser.add_argument("--model", help="teacher model (default: the CLI's own default)")
    parser.add_argument("--limit", type=int, help="label at most this many thoughts")
    parser.add_argument("--vocabulary", type=Path, default=vocab.DEFAULT_PATH,
                        help=f"vocabulary file (default: {vocab.DEFAULT_PATH})")
    parser.add_argument("--db", type=Path, default=argparse.SUPPRESS, help="database file (default: the app's)")
    parser.add_argument("--dry-run", action="store_true", help="show what would be sent; call no teacher")
    parser.set_defaults(run=run)


def run(args) -> int:
    terms = vocab.load_terms(args.vocabulary)
    try:
        con = db.connect(args.db, write=not args.dry_run)
    except db.SchemaError as error:
        print(f"irudd-voice: {error}", file=sys.stderr)
        return 1
    with con:
        chunks = pending_chunks(con, args.limit)
        if args.dry_run:
            print(f"Would label {len(chunks)} thought(s) with {args.teacher} "
                  f"(teacher prompt {teacher.load()['version']}, {len(terms)} vocabulary terms).")
            print("Command, run from an empty temporary folder:")
            print("  " + shlex.join(teacher.command(args.teacher, "<teacher system prompt>", args.model)))
            return 0
        if not chunks:
            print("Nothing to label: every transcribed thought has an accepted label.")
            return 0
        counts: Counter = Counter()
        reasons: Counter = Counter()
        cost = 0.0
        failed_in_a_row = 0
        for index, (chunk_id, transcript, day) in enumerate(chunks, 1):
            try:
                answer = teacher.ask(args.teacher, transcript, terms, args.model)
            except FileNotFoundError as error:
                print(f"irudd-voice: {error}", file=sys.stderr)
                return 1
            cost += answer.cost_usd or 0
            if answer.failure in teacher.CALL_FAILURES:
                # No label to judge: nothing is stored and the thought stays unlabeled.
                counts["failed"] += 1
                failed_in_a_row += 1
                print(f"[{index}/{len(chunks)}] #{chunk_id} call failed ({answer.failure}: {answer.detail})")
                if failed_in_a_row == MAX_FAILED_IN_A_ROW:
                    print(f"Stopping after {failed_in_a_row} failed calls in a row. "
                          f"Check that `{args.teacher}` works and is logged in.", file=sys.stderr)
                    break
                continue
            failed_in_a_row = 0
            status, reason = judge(transcript, answer, terms)
            store(con, chunk_id, day, answer, status, reason, args.teacher)
            counts[status] += 1
            if reason:
                reasons.update(reason.split(","))
            print(f"[{index}/{len(chunks)}] #{chunk_id} {status}{f' ({reason})' if reason else ''}")
    print(f"Labeled {counts['accepted'] + counts['rejected']}: {counts['accepted']} accepted, "
          f"{counts['rejected']} rejected" + (f"; {counts['failed']} call(s) failed" if counts["failed"] else ""))
    for reason, n in sorted(reasons.items(), key=lambda r: (-r[1], r[0])):
        print(f"  {reason}: {n}")
    if cost:
        print(f"Cost reported by {args.teacher}: ${cost:.4f}")
    return 1 if counts["failed"] and not (counts["accepted"] + counts["rejected"]) else 0
