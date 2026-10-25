"""`irudd-voice label` with fake teachers on PATH."""

import argparse
import json
import os
import signal
import sqlite3
import subprocess
import time
from pathlib import Path

import pytest
from labeling import FakeTeachers, add_chunk, add_label, rows

from irudd_voice import cli, dataset, db, prompt, teacher
from irudd_voice import label as label_module

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


def expected_outcome(case):
    if not case["cleaned"].strip():
        return ("rejected", "empty")
    if case["failures"]:
        return ("rejected", ",".join(case["failures"]))
    return ("accepted", None)


def test_shared_fixture_replies_are_accepted_or_rejected_exactly(app_db, fake, no_vocabulary, tmp_path, capsys):
    """Every hard-check fixture (traps and corrections) and every reply-format
    fixture becomes a chunk with a scripted teacher reply. Cases with a
    vocabulary are labeled in a later run with that vocabulary file."""
    expected = {}
    by_vocabulary = {}
    for case in CHECKS["checks"]:
        if case["transcript"] in expected or any(case in group for group in by_vocabulary.values()):
            continue
        if case["vocabulary"]:
            by_vocabulary.setdefault(tuple(case["vocabulary"]), []).append(case)
            continue
        add_chunk(app_db, case["transcript"])
        fake.reply(case["transcript"], case["cleaned"])
        expected[case["transcript"]] = expected_outcome(case)
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

    assert by_vocabulary
    for terms, cases in by_vocabulary.items():
        vocabulary = tmp_path / "vocabulary.json"
        vocabulary.write_text(json.dumps({"version": 1, "generated_at": "x", "terms": list(terms)}))
        for case in cases:
            add_chunk(app_db, case["transcript"])
            fake.reply(case["transcript"], case["cleaned"])
            expected[case["transcript"]] = expected_outcome(case)
        assert label(app_db, vocabulary) == 0
    assert labels(app_db) == expected


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


@pytest.mark.parametrize(("item_type", "status"), [
    ("view_image", "rejected"), ("image_generation", "rejected"), ("some_future_tool", "rejected"),
    ("reasoning", "accepted"), ("todo_list", "accepted"),
])
def test_codex_items_outside_the_allowlist_are_rejected(app_db, fake, no_vocabulary, item_type, status):
    add_chunk(app_db, "list the files")
    fake.reply("list the files", "List the files.", item_type=item_type)
    assert label(app_db, no_vocabulary, "--teacher", "codex") == 0
    assert labels(app_db) == {"list the files": (status, "ran_command" if status == "rejected" else None)}


def test_rejected_thoughts_are_skipped_unless_retried(app_db, fake, no_vocabulary):
    add_chunk(app_db, "run the tests")
    fake.reply("run the tests", "Run all the integration tests.")
    old = add_chunk(app_db, "rejected under an older prompt")
    con = sqlite3.connect(app_db)
    con.execute("INSERT INTO labels (chunk_id, status, reject_reason, teacher, teacher_prompt_version, created_at) "
                "VALUES (?, 'rejected', 'numbers', 'claude', 'teacher-v0', 'x')", (old,))
    con.commit()
    con.close()
    assert label(app_db, no_vocabulary) == 0
    assert len(fake.calls()) == 2  # the older prompt's rejection is asked again
    assert label(app_db, no_vocabulary) == 0
    assert len(fake.calls()) == 2
    fake.reply("run the tests", "Run the tests.")
    assert label(app_db, no_vocabulary, "--retry-rejected") == 0
    assert len(fake.calls()) == 3
    assert ("accepted", None) in rows(app_db, "SELECT l.status, l.reject_reason FROM labels l JOIN chunks c "
                                              "ON c.id = l.chunk_id WHERE c.raw_text = 'run the tests'")


def wait_until_gone(pid: int) -> bool:
    for _ in range(50):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return True
        time.sleep(0.1)
    os.kill(pid, signal.SIGKILL)
    return False


def test_ctrl_c_stops_the_teacher_and_its_children(fake, tmp_path, monkeypatch):
    """Ctrl-C reaches only the CLI (the teacher has its own session); ask()
    must kill the teacher's whole process group and re-raise."""
    pid_file = tmp_path / "child.pid"
    fake.reply("run the tests", hang=str(pid_file))
    real_popen = subprocess.Popen
    started = []

    class Interrupted(real_popen):
        def communicate(self, input=None, timeout=None):
            if started:  # the cleanup's own communicate
                return super().communicate(input, timeout)
            started.append(self.pid)
            self.stdin.write(input)
            self.stdin.close()
            for _ in range(100):
                if pid_file.exists() and pid_file.read_text():
                    break
                time.sleep(0.05)
            raise KeyboardInterrupt

    monkeypatch.setattr(subprocess, "Popen", Interrupted)
    with pytest.raises(KeyboardInterrupt):
        teacher.ask("claude", "run the tests")
    child = int(pid_file.read_text())
    assert wait_until_gone(child), "the teacher's child process outlived Ctrl-C"
    assert wait_until_gone(started[0]), "the teacher outlived Ctrl-C"


def test_a_hanging_teacher_is_killed_with_its_children(app_db, fake, no_vocabulary, tmp_path, monkeypatch):
    pid_file = tmp_path / "child.pid"
    add_chunk(app_db, "run the tests")
    fake.reply("run the tests", hang=str(pid_file))
    monkeypatch.setattr(teacher, "TIMEOUT_SECONDS", 2)
    assert label(app_db, no_vocabulary) == 1
    assert wait_until_gone(int(pid_file.read_text())), "the teacher's child process outlived the timeout"
    assert rows(app_db, "SELECT COUNT(*) FROM labels") == [(0,)]


def test_a_chunk_deleted_mid_run_is_skipped(app_db, fake, no_vocabulary, capsys):
    add_chunk(app_db, "delete me")
    add_chunk(app_db, "keep me")
    fake.reply("delete me", "Delete me.", delete_chunk=str(app_db))
    assert label(app_db, no_vocabulary) == 0
    assert labels(app_db) == {"keep me": ("accepted", None)}
    assert "1 deleted meanwhile" in capsys.readouterr().out


def test_default_database_without_db_flag(app_db, fake, no_vocabulary, monkeypatch, capsys):
    """Works whether the top-level --db defaults to db.DEFAULT_PATH (this
    branch) or to None (t3/py-models)."""
    add_chunk(app_db, "run the tests")
    monkeypatch.setattr(db, "DEFAULT_PATH", app_db)
    assert cli.main(["label", "--dry-run", "--vocabulary", str(no_vocabulary)]) == 0
    assert "Would label 1 thought(s)" in capsys.readouterr().out
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", type=Path, default=None)
    commands = parser.add_subparsers(dest="command", required=True)
    label_module.register(commands)
    dataset.register(commands)
    args = parser.parse_args(["label", "--vocabulary", str(no_vocabulary)])
    assert args.db is None and args.run(args) == 0
    assert rows(app_db, "SELECT status FROM labels") == [("accepted",)]
    args = parser.parse_args(["dataset", "build", "--out", str(app_db.parent / "out"),
                              "--vocabulary", str(no_vocabulary)])
    assert args.db is None and args.run(args) == 0
    assert rows(app_db, "SELECT COUNT(*) FROM dataset_days") == [(1,)]


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
        assert "--safe-mode" in argv
        assert "--bare" not in argv
        assert argv[argv.index("--system-prompt") + 1] == teacher.messages("x")[0]
    else:
        assert argv[:1] == ["exec"]
        for flag in ("--ephemeral", "--ignore-user-config", "--skip-git-repo-check", "--json"):
            assert flag in argv
        # The permission profile replaces -s: with both, -s wins and the home folder is readable.
        assert "-s" not in argv and "--sandbox" not in argv
        settings = [argv[i + 1] for i, flag in enumerate(argv) if flag == "-c"]
        assert settings == [
            'web_search="disabled"',
            'default_permissions="irudd_voice_teacher"',
            'permissions.irudd_voice_teacher.filesystem={":minimal"="read", ":slash_tmp"="none"}',
            "permissions.irudd_voice_teacher.network.enabled=false",
        ]
        disabled = {argv[i + 1] for i, flag in enumerate(argv) if flag == "--disable"}
        assert disabled == {"shell_tool", "unified_exec", "view_image", "image_generation", "multi_agent",
                            "plugins", "apps", "hooks", "computer_use", "browser_use"}
        assert argv[-1] == "-"
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
    assert label(app_db, no_vocabulary, "--limit", "2", "--retry-rejected") == 0
    # Never-tried chunks come before ones that were rejected before.
    assert rows(app_db, "SELECT chunk_id FROM labels WHERE id > 2 ORDER BY id") == [(first,), (second,)]
    assert label(app_db, no_vocabulary, "--retry-rejected") == 0
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
