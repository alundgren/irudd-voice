"""`irudd-voice label` with fake teachers on PATH."""

import json
import sqlite3
from pathlib import Path

import pytest
from labeling import FakeTeachers, add_chunk, add_label, rows

from irudd_voice import cli, prompt, teacher

SHARED = Path(__file__).resolve().parents[2] / "shared"
CHECKS = json.loads((SHARED / "fixtures/hard-checks.json").read_text())


@pytest.fixture
def fake(tmp_path, monkeypatch):
    return FakeTeachers(tmp_path, monkeypatch)


@pytest.fixture
def no_vocabulary(tmp_path):
    return tmp_path / "no-vocabulary.json"


def label(app_db, vocabulary, *extra):
    return cli.main(["label", "--db", str(app_db), "--vocabulary", str(vocabulary), *extra])


def labels(app_db):
    return {text: (status, reason) for text, status, reason in rows(
        app_db, "SELECT c.raw_text, l.status, l.reject_reason FROM labels l JOIN chunks c ON c.id = l.chunk_id")}


def test_shared_fixture_replies_are_accepted_or_rejected_exactly(app_db, fake, no_vocabulary, capsys):
    """Every hard-check fixture (traps and corrections) and every reply-format
    fixture becomes a chunk with a scripted teacher reply."""
    expected = {}
    for case in CHECKS["checks"]:
        if case["vocabulary"] or case["transcript"] in expected:
            continue
        add_chunk(app_db, case["transcript"])
        fake.reply(case["transcript"], case["cleaned"])
        if not case["cleaned"].strip():
            expected[case["transcript"]] = ("rejected", "empty")
        elif case["failures"]:
            expected[case["transcript"]] = ("rejected", ",".join(case["failures"]))
        else:
            expected[case["transcript"]] = ("accepted", None)
    for case in CHECKS["replies"]:
        transcript = f"reply format case {case['name']}"
        add_chunk(app_db, transcript)
        fake.reply(transcript, text=case["reply"].replace(case["cleaned"] or "\0", transcript))
        expected[transcript] = ("accepted", None) if case["failure"] is None else ("rejected", "malformed")
    assert len(expected) >= 70

    assert label(app_db, no_vocabulary) == 0
    assert labels(app_db) == expected
    summary = capsys.readouterr().out
    accepted = sum(1 for status, _ in expected.values() if status == "accepted")
    assert f"Labeled {len(expected)}: {accepted} accepted, {len(expected) - accepted} rejected" in summary
    assert "  malformed: " in summary and "  numbers: " in summary


@pytest.mark.parametrize(("transcript", "cleaned", "reason"), [
    ("set the timeout to fifty seconds", "Set the timeout to fifteen seconds.", "numbers"),
    ("do not delete the cache", "Delete the cache.", "negation"),
    ("rename get_user_name in the parser", "Rename the getter in the parser.", "identifiers,new_words"),
    ("run the tests", "Run the integration tests.", "new_words"),
    ("can you explain why the build failed", "Sure, the build failed because of a missing file.",
     "dropped,answers,question,new_words"),
])
def test_traps_are_rejected(app_db, fake, no_vocabulary, transcript, cleaned, reason):
    add_chunk(app_db, transcript)
    fake.reply(transcript, cleaned)
    assert label(app_db, no_vocabulary) == 0
    assert labels(app_db) == {transcript: ("rejected", reason)}


@pytest.mark.parametrize(("transcript", "reply"), [
    ("set the port to eighty", {"text": "Set the port to 80, okay?"}),
    ("set the port to eighty", {"text": '{"cleaned": "x", "extra": 1}'}),
    ("set the port to eighty", {"text": '{"cleaned": 80}'}),
    ("set the port to eighty", {"text": ""}),
])
def test_malformed_replies_are_rejected(app_db, fake, no_vocabulary, transcript, reply):
    add_chunk(app_db, transcript)
    fake.reply(transcript, **reply)
    assert label(app_db, no_vocabulary) == 0
    assert labels(app_db) == {transcript: ("rejected", "malformed")}


def test_failed_calls_store_nothing_and_stop_after_three(app_db, fake, no_vocabulary, capsys):
    for n in range(5):
        add_chunk(app_db, f"thought {n}")
        fake.reply(f"thought {n}", exit=1)
    assert label(app_db, no_vocabulary) == 1
    assert len(fake.calls()) == 3
    assert rows(app_db, "SELECT COUNT(*) FROM labels") == [(0,)]
    captured = capsys.readouterr()
    assert "Labeled 0: 0 accepted, 0 rejected; 3 call(s) failed" in captured.out
    assert "Stopping after 3 failed calls in a row" in captured.err


def test_corrections_case_and_punctuation(app_db, fake, no_vocabulary):
    cases = {
        "set the timeout to fifteen seconds no fifty seconds": "Set the timeout to fifty seconds.",
        "um open the readme file please": "Open the README file, please!",
        "Push THE branch": "push the branch",
    }
    for transcript, cleaned in cases.items():
        add_chunk(app_db, transcript)
        fake.reply(transcript, cleaned)
    assert label(app_db, no_vocabulary) == 0
    assert labels(app_db) == {t: ("accepted", None) for t in cases}


def test_vocabulary_reaches_the_teacher_and_the_checks(app_db, fake, tmp_path):
    vocabulary = tmp_path / "vocabulary.json"
    vocabulary.write_text(json.dumps({"version": 1, "generated_at": "2026-10-25T10:00:00Z",
                                      "terms": ["T3 Code", "SwiftUI"]}))
    add_chunk(app_db, "open tee three code and the swift you eye preview")
    fake.reply("open tee three code and the swift you eye preview", "Open T3 Code and the SwiftUI preview.")
    assert label(app_db, vocabulary) == 0
    assert labels(app_db) == {"open tee three code and the swift you eye preview": ("accepted", None)}
    assert "Vocabulary (use these spellings): T3 Code, SwiftUI" in fake.calls()[0]["argv"][
        fake.calls()[0]["argv"].index("--system-prompt") + 1]


def test_stored_fields_claude(app_db, fake, no_vocabulary, capsys):
    chunk = add_chunk(app_db, "um run the tests")
    fake.reply("um run the tests", "Run the tests.")
    assert label(app_db, no_vocabulary) == 0
    [row] = rows(app_db, "SELECT chunk_id, text, status, reject_reason, teacher, teacher_model, "
                         "teacher_prompt_version, cost_usd, input_tokens, output_tokens, frozen, created_at FROM labels")
    assert row[:11] == (chunk, "Run the tests.", "accepted", None, "claude", "claude-fake-opus",
                        teacher.load()["version"], 0.0125, 352, 25, 0)
    assert row[11].endswith("Z") and "T" in row[11]
    assert "Cost reported by claude: $0.0125" in capsys.readouterr().out


def test_claude_structured_output_is_used(app_db, fake, no_vocabulary):
    add_chunk(app_db, "run the tests")
    fake.reply("run the tests", text="", structured={"cleaned": "Run the tests."})
    assert label(app_db, no_vocabulary) == 0
    assert rows(app_db, "SELECT text, status FROM labels") == [("Run the tests.", "accepted")]


def test_stored_fields_codex(app_db, fake, no_vocabulary):
    add_chunk(app_db, "run the tests")
    fake.reply("run the tests", "Run the tests.")
    assert label(app_db, no_vocabulary, "--teacher", "codex", "--model", "gpt-fake") == 0
    assert rows(app_db, "SELECT text, status, teacher, teacher_model, cost_usd, input_tokens, output_tokens "
                        "FROM labels") == [("Run the tests.", "accepted", "codex", "gpt-fake", None, 900, 30)]


def test_codex_running_a_command_is_rejected(app_db, fake, no_vocabulary):
    add_chunk(app_db, "list the files")
    fake.reply("list the files", "List the files.", command=True)
    assert label(app_db, no_vocabulary, "--teacher", "codex") == 0
    assert labels(app_db) == {"list the files": ("rejected", "ran_command")}


@pytest.mark.parametrize("name", teacher.TEACHERS)
def test_teachers_run_contained_and_see_only_text(app_db, fake, no_vocabulary, name):
    add_chunk(app_db, "check the {rule} placeholder in prompt.py")
    assert label(app_db, no_vocabulary, "--teacher", name) == 0
    [call] = fake.calls()
    argv = call["argv"]
    if name == "claude":
        for flag in ("-p", "--strict-mcp-config", "--no-session-persistence", "--disable-slash-commands"):
            assert flag in argv
        assert argv[argv.index("--tools") + 1] == ""
        assert json.loads(argv[argv.index("--settings") + 1]) == {"disableAllHooks": True}
        assert argv[argv.index("--output-format") + 1] == "json"
        assert json.loads(argv[argv.index("--json-schema") + 1])["required"] == ["cleaned"]
        assert "--bare" not in argv
        assert argv[argv.index("--system-prompt") + 1] == teacher.messages("x")[0]
    else:
        assert argv[:1] == ["exec"]
        for flag in ("--ephemeral", "--ignore-user-config", "--skip-git-repo-check", "--json"):
            assert flag in argv
        assert argv[argv.index("-s") + 1] == "read-only"
        assert Path(argv[argv.index("--output-schema") + 1]) == SHARED / "teacher-reply.schema.json"
    # A fresh empty folder, removed afterwards.
    assert Path(call["cwd"]).name.startswith(teacher.TEACHER_DIR_PREFIX)
    assert call["cwd_listing"] == []
    assert not Path(call["cwd"]).exists()
    # The prompt holds the marker and the transcript, nothing else from the database.
    assert teacher.load()["marker"] in call["stdin"]
    assert '{"transcript": "check the {rule} placeholder in prompt.py"}' in call["stdin"]
    for private in ("SECRET-MIC-UID", "Secret mic name", "2026-10-20"):
        assert private not in call["stdin"] and private not in " ".join(argv)


def test_skips_labeled_discarded_and_empty_and_honours_limit(app_db, fake, no_vocabulary):
    done = add_chunk(app_db, "already labeled")
    add_label(app_db, done, "Already labeled.")
    add_chunk(app_db, "thrown away", status="discarded")
    add_chunk(app_db, "   ")
    retried = add_chunk(app_db, "rejected before")
    add_label(app_db, retried, None, status="rejected")
    first = add_chunk(app_db, "first new one")
    second = add_chunk(app_db, "second new one")
    assert label(app_db, no_vocabulary, "--limit", "2") == 0
    # Never-tried chunks come before ones that were rejected before.
    assert rows(app_db, "SELECT chunk_id FROM labels WHERE id > 2 ORDER BY id") == [(first,), (second,)]
    assert label(app_db, no_vocabulary) == 0
    assert len(fake.calls()) == 3
    assert label(app_db, no_vocabulary) == 0
    assert len(fake.calls()) == 3


def test_dry_run_calls_no_teacher_and_writes_nothing(app_db, fake, no_vocabulary, capsys):
    add_chunk(app_db, "run the tests")
    assert label(app_db, no_vocabulary, "--dry-run", "--teacher", "codex") == 0
    out = capsys.readouterr().out
    assert "Would label 1 thought(s) with codex" in out
    assert "--ephemeral" in out and "--output-schema" in out
    assert fake.calls() == []
    assert rows(app_db, "SELECT COUNT(*) FROM labels") == [(0,)]


def test_labels_on_test_days_are_frozen(app_db, fake, no_vocabulary):
    add_chunk(app_db, "run the tests", day="2026-10-21")
    con = sqlite3.connect(app_db)
    con.execute("INSERT INTO dataset_days VALUES ('2026-10-21', 'test', '2026-10-25T10:00:00.000Z')")
    con.commit()
    con.close()
    assert label(app_db, no_vocabulary) == 0
    assert rows(app_db, "SELECT status, frozen FROM labels") == [("accepted", 1)]


def test_teacher_prompt_reuses_the_cleanup_rules():
    system, user = teacher.messages("hello there", ["T3 Code"])
    cleanup_system, cleanup_user = (m["content"] for m in prompt.messages("hello there", ["T3 Code"]))
    assert cleanup_system in system
    assert user.startswith(teacher.load()["marker"] + "\n\n")
    assert user.endswith(cleanup_user)
