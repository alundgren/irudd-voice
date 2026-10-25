"""`irudd-voice vocab` on synthetic Claude, Codex and Cursor logs."""

import json
import sqlite3
from pathlib import Path

from irudd_voice import cli, teacher, vocab

DICTIONARY = {
    "the", "a", "to", "and", "in", "of", "run", "fix", "open", "check", "please", "test", "file", "build",
    "app", "with", "then", "commit", "it", "on", "use", "code", "done", "next", "update", "see", "port", "at",
    "ok", "is", "for", "mail", "or", "token", "key", "blob", "keep",
}


def jsonl(path: Path, lines: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(line) + "\n" for line in lines))


def claude_user(text, **extra):
    return {"type": "user", "cwd": extra.pop("cwd", "/work/irudd-voice"), "message": {"role": "user", "content": text},
            **extra}


def make_logs(home: Path) -> None:
    projects = home / ".claude" / "projects"
    for n in range(2):
        jsonl(projects / "-work-irudd-voice" / f"s{n}.jsonl", [
            claude_user("open hardchecks.py in irudd-voice and run pytest with uv please"),
            claude_user([{"type": "text", "text": "then fix getUserName in SwiftUI code"},
                         {"type": "image", "source": {}}]),
            # Not typed by the user: tool output, meta lines, subagents, system prompts.
            claude_user([{"type": "tool_result", "content": "toolresultword everywhere"}]),
            claude_user("metaword injected", isMeta=True),
            claude_user("compactword summary", isCompactSummary=True),
            claude_user("transcriptonlyword line", isVisibleInTranscriptOnly=True),
            claude_user("sidechainword prompt", isSidechain=True),
            claude_user("systemword notification", promptSource="system"),
            {"type": "assistant", "message": {"role": "assistant", "content": "assistantword reply"}},
            claude_user("<system-reminder>reminderword block</system-reminder> check the build. "
                        "see https://example.com/urlword and commit a1b2c3d4e5 /Users/someone/secretfolder and ~/private/notes"),
        ])
    # A teacher run left a log: skipped by its folder and by its marker.
    jsonl(projects / "-private-tmp-irudd-voice-teacher-abc" / "t.jsonl", [
        claude_user("teacherword one", cwd="/private/tmp/irudd-voice-teacher-abc")])
    jsonl(projects / "-work-other" / "t2.jsonl", [claude_user(teacher.load()["marker"] + " teacherword two")])
    jsonl(projects / "-work-other" / "t3.jsonl", [claude_user(teacher.load()["marker"] + " teacherword three")])

    sessions = home / ".codex" / "sessions" / "2026" / "10" / "24"
    for n in range(2):
        jsonl(sessions / f"rollout-{n}.jsonl", [
            {"type": "session_meta", "payload": {"cwd": "/work/irudd-voice"}},
            {"type": "response_item", "payload": {"type": "message", "role": "user", "content": [
                {"type": "input_text", "text": "# AGENTS.md instructions for /work\n\nagentsword rules"},
                {"type": "input_text", "text": "<environment_context>envword</environment_context>"},
                {"type": "input_text", "text": "update mlx-lm and the MLX build, then test xcodebuild"}]}},
            {"type": "response_item", "payload": {"type": "message", "role": "developer", "content": [
                {"type": "input_text", "text": "developerword"}]}},
        ])
    jsonl(sessions / "rollout-teacher.jsonl", [
        {"type": "session_meta", "payload": {"cwd": "/var/folders/x/irudd-voice-teacher-1"}},
        {"type": "response_item", "payload": {"type": "message", "role": "user", "content": [
            {"type": "input_text", "text": "teacherword codex"}]}}])

    cursor = home / ".cursor" / "projects"
    for n in range(2):
        jsonl(cursor / "work-irudd-voice" / "agent-transcripts" / f"agent-{n}" / f"agent-{n}.jsonl", [
            {"role": "user", "message": {"content": [{"type": "text", "text":
                "<timestamp>now</timestamp><user_query>check Qwen3.5 with mlx-lm</user_query>"
                "<runtime_info>runtimeword</runtime_info>"}]}},
            {"role": "assistant", "message": {"content": [{"type": "text", "text": "assistantword"}]}},
        ])

    app = home / "Library" / "Application Support" / "Cursor" / "User" / "globalStorage" / "state.vscdb"
    app.parent.mkdir(parents=True)
    con = sqlite3.connect(app)
    con.execute("CREATE TABLE cursorDiskKV (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)")
    for composer in ("c1", "c2"):
        con.execute("INSERT INTO cursorDiskKV VALUES (?, ?)",
                    (f"bubbleId:{composer}:b1", json.dumps({"type": 1, "text": "use TanStack in the app"})))
        con.execute("INSERT INTO cursorDiskKV VALUES (?, ?)",
                    (f"bubbleId:{composer}:b2", json.dumps({"type": 2, "text": "assistantword cursor"})))
    con.commit()
    con.close()


def test_terms_from_user_messages_only(tmp_path):
    make_logs(tmp_path)
    mined = vocab.mine(vocab.default_sources(tmp_path), DICTIONARY, skip={"someone"})
    assert set(mined.terms) == {
        "hardchecks.py", "irudd-voice", "pytest", "uv", "getUserName", "SwiftUI",
        "mlx-lm", "MLX", "xcodebuild", "Qwen3.5", "TanStack",
    }
    # Used in the most sessions first: irudd-voice (claude) and mlx-lm (codex and cursor) lead.
    assert mined.terms[0] == "mlx-lm"
    assert mined.sessions == {"claude": 2, "codex": 2, "cursor": 2, "cursor-app": 2}
    assert mined.teacher_sessions == 4


def test_terms_in_a_message():
    found = vocab.terms_in("Done.Next run the v2 build on port 8080 at 10s; see T3 and e2e tests in "
                           "Packages/IruddVoiceKit, ok?", DICTIONARY)
    assert found == ["v2", "T3", "e2e", "Packages", "IruddVoiceKit"]


def test_private_strings_are_never_terms():
    text = ("mail someone@example.com or first.last@mail.example.org; token ghp_abcDEF1234567890 and "
            "gho_xyz789, keys sk-proj-abc123 and xoxb-12-34-abc and AKIAIOSFODNN7EXAMPLE, blob "
            "aB3dE5fG7hI9jK1lM3nO5pQ7 on api.internal.example.dev, myhost.tail1234.ts.net, example.com "
            "and 192.168.1.20; keep hardchecks.py README.md Qwen3.5-2B mlx-lm getUserName")
    assert vocab.terms_in(text, DICTIONARY) == ["hardchecks.py", "README.md", "Qwen3.5-2B", "mlx-lm", "getUserName"]


def test_missing_sources_are_skipped(tmp_path):
    mined = vocab.mine(vocab.default_sources(tmp_path), DICTIONARY)
    assert mined.terms == [] and mined.teacher_sessions == 0


def test_command_writes_a_versioned_file(tmp_path, capsys):
    make_logs(tmp_path / "home")
    out = tmp_path / "vocabulary.json"
    assert cli.main(["vocab", "--home", str(tmp_path / "home"), "--out", str(out)]) == 0
    data = json.loads(out.read_text())
    assert data["version"] == 1 and data["generated_at"].endswith("Z")
    assert "irudd-voice" in data["terms"] and len(data["terms"]) <= 200
    assert vocab.load_terms(out) == data["terms"]
    printed = capsys.readouterr().out
    assert "teacher sessions skipped: 4" in printed


def test_dry_run_prints_counts_only(tmp_path, capsys):
    make_logs(tmp_path / "home")
    out = tmp_path / "vocabulary.json"
    assert cli.main(["vocab", "--home", str(tmp_path / "home"), "--out", str(out), "--dry-run"]) == 0
    printed = capsys.readouterr().out
    assert not out.exists()
    assert "Terms: " in printed
    for term in ("irudd-voice", "pytest", "SwiftUI", "TanStack"):
        assert term not in printed
