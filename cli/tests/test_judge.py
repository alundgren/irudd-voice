"""The judge prompt, its votes and the promotion rule. No model, no real teacher."""

import json

import pytest
from trainloop import FakeJudge, item, items

from irudd_voice import compare, judge, teacher


@pytest.mark.parametrize(("counts", "promotable"), [
    ({"win": 99}, False),  # 99 compared
    ({"win": 100}, True),  # 100 compared
    ({"win": 11, "loss": 9, "same": 80}, True),  # exactly 55%
    ({"win": 55, "loss": 45}, True),
    ({"win": 54, "loss": 46}, False),
    ({"win": 10, "loss": 9, "same": 81}, False),  # 52.6%
    ({"win": 11, "loss": 9, "tie": 50, "same": 30}, True),  # ties don't count
    ({"tie": 60, "same": 40}, False),  # nothing decided
    ({"win": 10, "loss": 9, "split": 81}, False),  # order disagreements don't count as wins
    ({"win": 11, "loss": 9, "split": 70, "failed": 10}, True),
])
def test_promotion_rule_edges(counts, promotable):
    assert compare.decide(items(**counts))["promotable"] is promotable


def test_rule_reasons_name_every_problem():
    rows = items(win=5, loss=5, same=89)
    rows.append(item(100, judge.SAME, cand_failures=["numbers"]))
    reasons = compare.decide(rows)["reasons"]
    assert reasons == ["won 5 of 10 decided votes (50.0%); promotion needs 55%",
                       "fails hard checks the incumbent passed (numbers 1)"]
    assert compare.decide(items(win=3))["reasons"][0] == "only 3 test thoughts compared; promotion needs 100"


def test_a_new_hard_check_failure_blocks_promotion():
    rows = items(win=100)
    assert compare.decide(rows)["promotable"]
    rows[7] = item(8, judge.WIN, cand_failures=["negation"])
    assert not compare.decide(rows)["promotable"]
    # Failing a check the incumbent also failed on that thought isn't new.
    rows[7] = item(8, judge.WIN, cand_failures=["negation"], inc_failures=["negation", "numbers"])
    assert compare.decide(rows)["promotable"]
    # A different check on the same thought is new.
    rows[7] = item(8, judge.WIN, cand_failures=["negation"], inc_failures=["numbers"])
    assert compare.decide(rows)["reasons"] == ["fails hard checks the incumbent passed (negation 1)"]


def answers(*picks):
    """A fake ask_judge returning these picks in turn ("fail" fails)."""
    calls = []

    def ask(judge_name, transcript, a, b, terms, model):
        calls.append((a, b))
        pick = picks[len(calls) - 1]
        if pick == "fail":
            return teacher.Answer(None, "teacher_error")
        return teacher.Answer(pick, None, model="fake", cost_usd=0.01)

    return ask, calls


@pytest.mark.parametrize(("picks", "outcome"), [
    (("A", "B"), judge.WIN),  # candidate is A first, then B
    (("B", "A"), judge.LOSS),
    (("A", "A"), judge.SPLIT),  # picked by position, not by text
    (("tie", "tie"), judge.TIE),
    (("A", "tie"), judge.SPLIT),
    (("fail", "A"), judge.FAILED),
    (("A", "fail"), judge.FAILED),
])
def test_votes_count_only_when_both_orders_agree(picks, outcome):
    ask, calls = answers(*picks)
    vote = judge.vote("claude", "um set it to five", "Set it to five.", "Set it to 5.", ask_judge=ask)
    assert vote.outcome == outcome
    assert calls[0] == ("Set it to five.", "Set it to 5.")
    if len(calls) == 2:
        assert calls[1] == ("Set it to 5.", "Set it to five.")


def test_identical_outputs_need_no_judge():
    ask, calls = answers()
    assert judge.vote("claude", "hi", "Hi.", "Hi.", ask_judge=ask).outcome == judge.SAME
    assert calls == []


def test_judge_prompt_shows_transcript_and_both_outputs_but_no_label():
    system, user = judge.messages('say "hi" {rule}', "A text", "B text", ["SQLite"])
    assert user.startswith(judge.load()["marker"])
    data = json.loads(user.split("\n\n")[1])
    assert data == {"transcript": 'say "hi" {rule}', "A": "A text", "B": "B text"}
    assert "SQLite" in system and "1. Same meaning" in system and "6. Light touch and tone" in system
    assert "{checklist}" not in system


@pytest.mark.parametrize(("text", "value"), [
    ('{"better": "A"}', ("A", None)),
    ('```json\n{"better": "tie"}\n```', ("tie", None)),
    ('{"better": "C"}', (None, "malformed")),
    ('{"better": "A", "why": "x"}', (None, "malformed")),
    ("A", (None, "malformed")),
])
def test_judge_replies(text, value):
    assert judge.read_pick(text) == value


@pytest.mark.parametrize("name", teacher.TEACHERS)
def test_judge_runs_contained_like_a_label(tmp_path, monkeypatch, name):
    fake = FakeJudge(tmp_path, monkeypatch)
    fake.rule("make it green", prefer="Make it green.")
    vote = judge.vote(name, "make it green", "Make it green.", "Make it blue.")
    assert vote.outcome == judge.WIN
    calls = fake.calls()
    assert len(calls) == 2
    for call in calls:
        assert call["cwd_listing"] == [] and teacher.TEACHER_DIR_PREFIX in call["cwd"]
        argv = call["argv"]
        if name == "claude":
            assert argv[:argv.index("--system-prompt")] == [
                "-p", "--tools", "", "--strict-mcp-config", "--no-session-persistence",
                "--disable-slash-commands", "--safe-mode", "--settings", '{"disableAllHooks":true}']
            schema = json.loads(argv[argv.index("--json-schema") + 1])
            assert schema["properties"]["better"]["enum"] == ["A", "B", "tie"]
        else:
            assert argv[argv.index("--output-schema") + 1].endswith("judge-reply.schema.json")
            for setting in teacher.CODEX_PERMISSIONS:
                assert setting in argv
            assert all(feature in argv for feature in teacher.CODEX_DISABLED_FEATURES)
            # Codex has no system prompt flag: the rules come first on stdin.
            assert call["stdin"].startswith(judge.load()["system_before"])
