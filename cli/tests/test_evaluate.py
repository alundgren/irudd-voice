"""Eval scoring with a fake generator, and the committed eval sets."""

import json
from pathlib import Path

import pytest

from irudd_voice import evaluate, hardchecks, parity, prompt, train

EVALS = Path(__file__).resolve().parents[2] / "evals"


def rows(name):
    return [json.loads(line) for line in (EVALS / f"{name}.jsonl").read_text().splitlines()]


def test_similarity():
    assert evaluate.similarity("abc", "abc") == 1.0
    assert evaluate.similarity("", "") == 1.0
    assert evaluate.similarity("abcd", "abce") == 0.75
    assert evaluate.similarity("", "abc") == 0.0
    assert evaluate.edit_distance("kitten", "sitting") == 3


def expected_by_transcript():
    return {r["transcript"]: r["expected"] for name in evaluate.SETS for r in rows(name)}


def fake(reply_for, hit_limit=False):
    return lambda transcript, terms: evaluate.Output(reply_for(transcript), hit_limit, 0.1)


def test_a_perfect_model_passes():
    expected = expected_by_transcript()
    report = evaluate.run(fake(lambda t: train.reply_text(expected[t])), list(evaluate.SETS), log=lambda _: None)
    questions = report["sets"]["questions"]["summary"]
    transcripts = report["sets"]["transcripts"]["summary"]
    assert questions["passed"] == 40 and transcripts["passed"] == 50
    assert transcripts["mean_similarity"] == 1.0 and transcripts["exact"] == 50
    assert report["hard_check_gate"] == {"questions_with_failures": 0, "transcripts_with_failures": 0,
                                         "passes_hard_checks": True}
    assert report["sets"]["questions"]["sha256"] and report["prompt_version"] == "cleanup-v1"


def test_answering_and_broken_replies_fail():
    answers = evaluate.run(fake(lambda t: train.reply_text("Sure, here is the answer you wanted.")), ["questions"],
                           log=lambda _: None)
    summary = answers["sets"]["questions"]["summary"]
    assert summary["passed"] == 0 and summary["failures_by_check"]["answers"] == 40
    cut = evaluate.run(fake(lambda t: '{"cleaned": "Set the', hit_limit=True), ["transcripts"], log=lambda _: None)
    assert cut["sets"]["transcripts"]["summary"]["failures_by_check"] == {"cut_off": 50}
    item = cut["sets"]["transcripts"]["items"][0]
    assert item["similarity"] is None
    assert item["pasted_similarity"] == round(evaluate.similarity(item["transcript"], item["expected"]), 4)
    assert "passes_hard_checks" not in cut["hard_check_gate"]


def test_percentiles():
    assert evaluate.percentile([3, 1, 2], 50) == 2
    assert evaluate.percentile(list(range(1, 11)), 90) == 9
    assert evaluate.percentile([], 50) is None


@pytest.mark.parametrize("name, count", [("questions", 40), ("transcripts", 50), ("parity", 20)])
def test_eval_sets_are_valid(name, count):
    items = rows(name)
    assert len(items) == count
    assert len({i["id"] for i in items}) == count
    for item in items:
        assert item["transcript"].strip()
        if name != "parity":
            assert hardchecks.check(item["transcript"], item["expected"]) == [], item["id"]


def test_parity_inputs_cover_escaping():
    text = "".join(i["transcript"] for i in rows("parity"))
    for char in ("/", "’", '"', "\n", "\\", "\t"):
        assert char in text
    assert any(i["vocabulary"] for i in rows("parity"))
    assert parity.DEFAULT_INPUTS == EVALS / "parity.jsonl"


WORDS = "alpha bravo charlie delta echo foxtrot golf hotel india juliet".split()


def sentences(count):
    return " ".join(" ".join(WORDS) + "." for _ in range(count))


def test_a_long_thought_is_cleaned_in_pieces_like_the_app():
    transcript = sentences(15)  # 150 words: two pieces
    seen = []

    def generate(piece, terms):
        seen.append(piece)
        return evaluate.Output(train.reply_text(piece.capitalize()), False, 0.5)

    scored = evaluate.score_thought({"id": 1, "transcript": transcript}, generate, prompt.load())
    assert seen == [sentences(12), " ".join(transcript.split()[120:])]
    assert all(len(piece.split()) <= 120 for piece in seen)
    assert scored["failures"] == [] and scored["pieces"] == 2 and scored["seconds"] == 1.0
    assert scored["pasted"] == scored["cleaned"] == " ".join(piece.capitalize() for piece in seen)


def test_a_failing_piece_pastes_the_whole_transcript():
    transcript = sentences(15)
    calls = []

    def generate(piece, terms):
        calls.append(piece)
        if len(calls) == 1:
            return evaluate.Output(train.reply_text(piece), False, 0.5)
        return evaluate.Output('{"cleaned": "w', False, 5.0, timed_out=True)

    scored = evaluate.score_thought({"id": 1, "transcript": transcript}, generate, prompt.load())
    assert scored["failures"] == ["timeout"]
    assert scored["pasted"] == transcript
    assert scored["cleaned"] == calls[0]  # what the model said for the pieces it got to


def test_a_timed_out_reply_is_never_used():
    item = {"id": 1, "transcript": "set the port to eighty"}
    scored = evaluate.score_item(item, evaluate.Output(train.reply_text("Set the port to eighty."), False, 5.0,
                                                       timed_out=True), prompt.load())
    assert scored["failures"] == ["timeout"] and scored["cleaned"] is None


def test_nothing_left_after_cleanup_pastes_the_transcript():
    scored = evaluate.score_thought({"id": 1, "transcript": "um"},
                                    lambda piece, terms: evaluate.Output(train.reply_text(""), False, 0.1),
                                    prompt.load())
    assert scored["failures"] == ["empty"] and scored["pasted"] == "um"
