"""`irudd-voice dataset build`: day splits, frozen test labels, mlx-lm files."""

import hashlib
import json
from datetime import date, timedelta

import pytest
from labeling import add_chunk, add_label, rows

from irudd_voice import cli, dataset, db, hardchecks, prompt


def days(start: str, count: int) -> list[str]:
    first = date.fromisoformat(start)
    return [(first + timedelta(days=n)).isoformat() for n in range(count)]


def record_days(app_db, day_list, per_day=2):
    """Each day gets labeled chunks, one rejected-only chunk and one discarded chunk."""
    for day in day_list:
        for n in range(per_day):
            chunk = add_chunk(app_db, f"um run test {n} on {day} please", day=day)
            add_label(app_db, chunk, f"Run test {n} on {day}, please.")
        add_label(app_db, add_chunk(app_db, f"rejected on {day}", day=day), None, status="rejected")
        add_chunk(app_db, f"discarded on {day}", day=day, status="discarded")


def build(app_db, out, *extra):
    return cli.main(["dataset", "build", "--db", str(app_db), "--out", str(out),
                     "--vocabulary", str(out.parent / "none.json"), *extra])


def splits(app_db):
    return dict(rows(app_db, "SELECT local_day, split FROM dataset_days"))


def test_days_never_move_and_test_labels_freeze(app_db, tmp_path):
    record_days(app_db, days("2026-09-01", 20))
    assert build(app_db, tmp_path / "one") == 0
    first = splits(app_db)
    first_rows = rows(app_db, "SELECT * FROM dataset_days ORDER BY local_day")
    frozen_before = rows(app_db, "SELECT id, text, frozen FROM labels WHERE frozen = 1 ORDER BY id")
    assert len(first) == 20 and "test" in first.values() and "selection" in first.values()

    record_days(app_db, days("2026-09-21", 10))
    assert build(app_db, tmp_path / "two") == 0
    second = splits(app_db)
    assert len(second) == 30
    # Old days keep their split and assignment time; their frozen labels are unchanged.
    assert rows(app_db, "SELECT * FROM dataset_days WHERE local_day < '2026-09-21' ORDER BY local_day") == first_rows
    assert set(frozen_before) <= set(rows(app_db, "SELECT id, text, frozen FROM labels WHERE frozen = 1"))
    for share in (len([s for s in first.values() if s == "test"]) / 20,
                  len([s for s in second.values() if s == "test"]) / 30):
        assert 0.10 <= share <= 0.20

    # Every label on a test day is frozen; no label elsewhere is.
    for day, split, frozen in rows(app_db, "SELECT c.local_day, d.split, l.frozen FROM labels l "
                                           "JOIN chunks c ON c.id = l.chunk_id JOIN dataset_days d USING (local_day)"):
        assert frozen == (1 if split == "test" else 0), day

    # Each file holds only its split's days, with the day's labeled chunks.
    for split, name in dataset.FILES.items():
        lines = (tmp_path / "two" / name).read_text().splitlines()
        assert len(lines) == 2 * sum(1 for s in second.values() if s == split)
        for line in lines:
            user = json.loads(line)["messages"][1]["content"]
            assert second[user.split(" on ")[1].split(" ")[0]] == split


def test_split_shares_hold_as_days_arrive_one_at_a_time():
    existing = {}
    for n, day in enumerate(days("2025-01-01", 200), 1):
        existing |= dataset.assign(existing, [*existing, day])
        test = sum(1 for s in existing.values() if s == "test")
        selection = sum(1 for s in existing.values() if s == "selection")
        if n < 3:
            assert test == 0
        elif n < 5:
            assert test == 1
        else:
            assert 0.10 <= test / n <= 0.20, n
        if n >= 4:
            assert selection >= 1
    # Same days added in one go: the same answer.
    assert dataset.assign({}, list(existing)) == existing


def test_assignment_is_seeded_by_the_day():
    a = dataset.assign({}, days("2026-01-01", 40))
    b = dataset.assign({}, list(reversed(days("2026-01-01", 40))))
    assert a == b


def test_example_lines_are_mlx_chat_format(app_db, tmp_path):
    chunk = add_chunk(app_db, 'say "hi" then\ttab', day="2026-10-01")
    add_label(app_db, chunk, 'Say "hi", then tab.')
    vocabulary = tmp_path / "vocabulary.json"
    vocabulary.write_text(json.dumps({"version": 1, "generated_at": "x", "terms": ["T3 Code"]}))
    out = tmp_path / "out"
    assert cli.main(["dataset", "build", "--db", str(app_db), "--out", str(out), "--vocabulary", str(vocabulary)]) == 0
    [line] = [l for name in dataset.FILES.values() for l in (out / name).read_text().splitlines()]
    messages = json.loads(line)["messages"]
    assert messages[:2] == prompt.messages('say "hi" then\ttab', ["T3 Code"])
    assert messages[2] == {"role": "assistant", "content": '{"cleaned": "Say \\"hi\\", then tab."}'}
    assert hardchecks.parse_reply(messages[2]["content"]).cleaned == 'Say "hi", then tab.'
    summary = json.loads((out / "dataset.json").read_text())
    assert summary["prompt_version"] == prompt.load()["version"]
    assert summary["vocabulary_terms"] == 1
    assert sum(summary["examples"].values()) == 1


def test_hash_is_stable_and_follows_the_content(app_db, tmp_path):
    record_days(app_db, days("2026-09-01", 6))
    assert build(app_db, tmp_path / "a") == 0
    assert build(app_db, tmp_path / "b") == 0
    hash_of = lambda name: json.loads((tmp_path / name / "dataset.json").read_text())["dataset_hash"]
    assert hash_of("a") == hash_of("b")
    con = db.connect(app_db, write=True)
    with db.write_transaction(con):
        con.execute("UPDATE labels SET text = 'Changed.' WHERE id = 1")
    con.close()
    assert build(app_db, tmp_path / "c") == 0
    assert hash_of("c") != hash_of("a")


def test_vocabulary_hash_is_recorded(app_db, tmp_path):
    record_days(app_db, days("2026-09-01", 3))
    vocabulary = tmp_path / "vocabulary.json"
    hashes = []
    for terms in (["T3 Code"], ["T3 Code", "SwiftUI"]):
        vocabulary.write_text(json.dumps({"version": 1, "generated_at": "x", "terms": terms}))
        out = tmp_path / f"out{len(terms)}"
        assert cli.main(["dataset", "build", "--db", str(app_db), "--out", str(out),
                         "--vocabulary", str(vocabulary)]) == 0
        summary = json.loads((out / "dataset.json").read_text())
        assert summary["vocabulary_hash"] == hashlib.sha256("".join(t + "\n" for t in terms).encode()).hexdigest()
        hashes.append(summary["vocabulary_hash"])
    assert hashes[0] != hashes[1]


def test_typed_variants_stay_in_their_split_and_test_gets_none(app_db, tmp_path):
    record_days(app_db, days("2026-09-01", 12))
    assert build(app_db, tmp_path / "plain") == 0
    assert build(app_db, tmp_path / "aug", "--augment-typed") == 0
    day_split = splits(app_db)
    plain = {name: (tmp_path / "plain" / name).read_text() for name in dataset.FILES.values()}
    augmented = {name: (tmp_path / "aug" / name).read_text() for name in dataset.FILES.values()}
    # Only train gets variants; selection and test stay real dictation.
    assert augmented["test.jsonl"] == plain["test.jsonl"]
    assert augmented["valid.jsonl"] == plain["valid.jsonl"]
    summary = json.loads((tmp_path / "aug" / "dataset.json").read_text())
    assert summary["augmented"] == {"train": summary["augmented"]["train"], "selection": 0, "test": 0}
    assert summary["augmented"]["train"] > 0
    for split, name in dataset.FILES.items():
        plain_lines = plain[name].splitlines()
        added = [l for l in augmented[name].splitlines() if l not in plain_lines]
        assert len(added) == summary["augmented"][split]
        for line in added:
            messages = json.loads(line)["messages"]
            label = json.loads(messages[2]["content"])["cleaned"]
            # The label names its own day, so the variant's source day is known.
            assert day_split[label.split(" on ")[1].split(",")[0]] == split
            transcript = json.loads(messages[1]["content"].split("\n\n")[0])["transcript"]
            assert hardchecks.check(transcript, label) == []


@pytest.mark.parametrize(("label", "expected"), [
    ("Open shared/cleanup-prompt.json, please.", "open shared/cleanup-prompt.json please"),
    ("Is getUserName used?", "is getUserName used"),
])
def test_spoken_form_keeps_identifiers(label, expected):
    assert dataset.spoken_form(label, 1).endswith(expected)
