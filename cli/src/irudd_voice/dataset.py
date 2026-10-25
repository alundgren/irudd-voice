"""`irudd-voice dataset build`: train, selection and test files for mlx-lm.

Whole recording days (each chunk's `local_day`) go to one split, recorded in
`dataset_days`. A day keeps its split forever, and labels on test days are
frozen (`labels.frozen` = 1). New days get their split from a hash of the
day, adjusted so the test share stays between 10% and 20% (target 15%) and
there is a test day once there are 3 or more days. The selection split
(mlx-lm's valid.jsonl) works the same way with a 10% target.

Each example is the cleanup prompt (prompt.messages) for the chunk's raw
text plus the assistant reply {"cleaned": <label>}, using the chunk's first
accepted label.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import random
import re
import sys
import tempfile
from collections import Counter
from datetime import UTC, datetime
from pathlib import Path

from . import db, hardchecks, prompt, vocab

VERSION = 1
TEST_SHARE = (0.10, 0.15, 0.20)  # minimum, target, maximum
SELECTION_SHARE = (0.05, 0.10, 0.15)
FILES = {"train": "train.jsonl", "selection": "valid.jsonl", "test": "test.jsonl"}


def day_hash(day: str) -> float:
    """A fixed number in [0, 1) for a day, the same on every machine."""
    return int.from_bytes(hashlib.sha256(f"irudd-voice-split:{day}".encode()).digest()[:8], "big") / 2**64


def bounds(share: tuple[float, float, float], days: int, at_least_one_from: int) -> tuple[int, int]:
    """(fewest, most) days a split may have out of `days`."""
    fewest = math.ceil(share[0] * days) if days >= at_least_one_from else 0
    return fewest, max(fewest, math.floor(share[2] * days))


def assign(existing: dict[str, str], days: list[str]) -> dict[str, str]:
    """Splits for the days in `days` that `existing` doesn't have yet. Old
    days never move. New days are handled oldest first, so the result only
    depends on the days themselves."""
    splits = dict(existing)
    new = {}
    for day in sorted(set(days) - set(existing)):
        total = len(splits) + 1
        counts = Counter(splits.values())
        u = day_hash(day)
        test_min, test_max = bounds(TEST_SHARE, total, 3)
        sel_min, sel_max = bounds(SELECTION_SHARE, total, 4)
        if counts["test"] < test_min:
            split = "test"
        elif counts["selection"] < sel_min:
            split = "selection"
        elif u < TEST_SHARE[1] and counts["test"] < test_max:
            split = "test"
        elif TEST_SHARE[1] <= u < TEST_SHARE[1] + SELECTION_SHARE[1] and counts["selection"] < sel_max:
            split = "selection"
        else:
            split = "train"
        splits[day] = new[day] = split
    return new


def assistant_reply(label: str) -> str:
    return '{"cleaned": ' + prompt.json_string(label) + "}"


def example(transcript: str, label: str, terms: list[str]) -> str:
    messages = prompt.messages(transcript, terms) + [{"role": "assistant", "content": assistant_reply(label)}]
    return json.dumps({"messages": messages}, ensure_ascii=False)


def spoken_form(label: str, seed: int) -> str:
    """The label as it might have been dictated: lowercase, no sentence
    punctuation, sometimes a filler in front. Words inside identifiers
    (dots, dashes, slashes) stay as they are."""
    rng = random.Random(seed)
    words = []
    for word in label.split():
        bare = re.sub(r"[.,!?;:]+$", "", word)
        bare = re.sub(r"^[\"'(]+|[\"')]+$", "", bare)
        words.append(bare if re.search(r"[a-z][A-Z]|[._/\-]\w", bare) else bare.lower())
    filler = rng.choice(["", "um ", "so ", "okay so ", "uh "])
    return filler + " ".join(w for w in words if w)


def typed_variants(chunk_id: int, transcript: str, label: str, terms: list[str]) -> list[str]:
    """Synthetic inputs for one accepted label: the label typed as it is
    (cleanup should leave it alone) and a spoken-looking version. Variants
    that repeat the real transcript or wouldn't pass the hard checks are
    dropped."""
    settings = prompt.load()["checks"]
    inputs = []
    for candidate in (label, spoken_form(label, chunk_id)):
        if candidate in inputs or candidate == transcript or not candidate.strip():
            continue
        if hardchecks.check(candidate, label, terms, settings["max_output_words_ratio"],
                            settings["max_output_words_slack"]):
            continue
        inputs.append(candidate)
    return inputs


def build(con, out: Path, terms: list[str], augment_typed: bool = False, now: str | None = None) -> dict:
    now = now or datetime.now(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")
    with db.write_transaction(con):
        days = [d for (d,) in con.execute(
            "SELECT DISTINCT local_day FROM chunks WHERE status = 'transcribed' ORDER BY local_day")]
        existing = dict(con.execute("SELECT local_day, split FROM dataset_days").fetchall())
        new = assign(existing, days)
        con.executemany("INSERT INTO dataset_days (local_day, split, assigned_at) VALUES (?, ?, ?)",
                        [(day, split, now) for day, split in new.items()])
        frozen = con.execute(
            "UPDATE labels SET frozen = 1 WHERE frozen = 0 AND chunk_id IN (SELECT c.id FROM chunks c "
            "JOIN dataset_days d ON d.local_day = c.local_day WHERE d.split = 'test')").rowcount
        rows = con.execute(
            "SELECT c.id, c.raw_text, d.split, l.text, l.teacher_prompt_version FROM chunks c "
            "JOIN dataset_days d ON d.local_day = c.local_day "
            "JOIN labels l ON l.id = (SELECT MIN(id) FROM labels WHERE chunk_id = c.id AND status = 'accepted') "
            "WHERE c.status = 'transcribed' AND TRIM(COALESCE(c.raw_text, '')) != '' "
            "ORDER BY c.local_day, c.id").fetchall()
        splits = dict(con.execute("SELECT local_day, split FROM dataset_days").fetchall())

    lines: dict[str, list[str]] = {split: [] for split in FILES}
    augmented: Counter = Counter()
    teacher_versions = set()
    for chunk_id, raw_text, split, label, teacher_version in rows:
        teacher_versions.add(teacher_version)
        lines[split].append(example(raw_text, label, terms))
        # Selection and test measure real dictation only, so only train gets variants.
        if augment_typed and split == "train":
            for variant in typed_variants(chunk_id, raw_text, label, terms):
                lines[split].append(example(variant, label, terms))
                augmented[split] += 1

    cleanup_version = prompt.load()["version"]
    used_terms = terms[: prompt.load()["vocabulary_limit"]]
    digest = hashlib.sha256(cleanup_version.encode() + b"\n")
    for line in sorted(f"{split}\t{line}" for split, split_lines in lines.items() for line in split_lines):
        digest.update(line.encode() + b"\n")

    out.mkdir(parents=True, exist_ok=True)
    for split, name in FILES.items():
        (out / name).write_text("".join(line + "\n" for line in lines[split]))
    summary = {
        "version": VERSION,
        "dataset_hash": digest.hexdigest(),
        "prompt_version": cleanup_version,
        "teacher_prompt_versions": sorted(teacher_versions),
        "vocabulary_terms": len(used_terms),
        # SHA-256 of the terms the prompts used, one per line in file order.
        "vocabulary_hash": hashlib.sha256("".join(t + "\n" for t in used_terms).encode()).hexdigest(),
        "augment_typed": augment_typed,
        "built_at": now,
        "examples": {split: len(lines[split]) for split in FILES},
        "augmented": {split: augmented[split] for split in FILES},
        "days": {split: sum(1 for s in splits.values() if s == split) for split in FILES},
        "new_days": len(new),
        "newly_frozen_labels": frozen,
    }
    (out / "dataset.json").write_text(json.dumps(summary, indent=2) + "\n")
    return summary


def register(commands) -> None:
    parser = commands.add_parser("dataset", help="training data from labeled thoughts")
    actions = parser.add_subparsers(dest="dataset_command", required=True)
    build_parser = actions.add_parser("build", help="assign day splits and write train/valid/test JSONL")
    build_parser.add_argument("--db", type=Path, default=argparse.SUPPRESS, help="database file (default: the app's)")
    build_parser.add_argument("--out", type=Path, help="output folder (default: a new temporary folder)")
    build_parser.add_argument("--vocabulary", type=Path, default=vocab.DEFAULT_PATH,
                              help=f"vocabulary file (default: {vocab.DEFAULT_PATH})")
    build_parser.add_argument("--augment-typed", action="store_true",
                              help="add typed-prompt variants of accepted labels (train only)")
    build_parser.set_defaults(run=run)


def run(args) -> int:
    # The top-level --db default may be None (resolved by each command).
    path = getattr(args, "db", None) or db.DEFAULT_PATH
    try:
        con = db.connect(path, write=True)
    except db.SchemaError as error:
        print(f"irudd-voice: {error}", file=sys.stderr)
        return 1
    out = args.out or Path(tempfile.mkdtemp(prefix="irudd-voice-dataset-"))
    with con:
        summary = build(con, out, vocab.load_terms(args.vocabulary), args.augment_typed)
    examples, days = summary["examples"], summary["days"]
    print(f"Days: {days['train']} train, {days['selection']} selection, {days['test']} test "
          f"({summary['new_days']} new)")
    print(f"Examples: {examples['train']} train, {examples['selection']} valid, {examples['test']} test"
          + (f" (incl. {sum(summary['augmented'].values())} typed variants)" if args.augment_typed else ""))
    print(f"Dataset {summary['dataset_hash'][:12]} written to {out}")
    return 0
