"""Helpers for the label and dataset tests: chunk rows and fake teachers."""

from __future__ import annotations

import json
import os
import sqlite3
import sys
import uuid
from pathlib import Path

from irudd_voice import db


def add_chunk(path: Path, text: str, day: str = "2026-10-20", status: str = "transcribed") -> int:
    """A chunk row the way the app saves one (the app's schema made the table)."""
    con = db.connect(path, write=True)
    stamp = f"{day}T10:00:00.000Z"
    with db.write_transaction(con):
        cursor = con.execute(
            "INSERT INTO chunks (uuid, status, started_at, signal_at, ended_at, local_day, utc_offset_minutes, "
            "duration_ms, start_reason, end_reason, mic_uid, mic_name, audio, audio_format, audio_sample_rate, "
            "audio_bytes, raw_text, recognizer, transcribed_at, schema_version, app_version, created_at, updated_at) "
            "VALUES (?, ?, ?, ?, ?, ?, 60, 2000, 'unmute', 'muteButton', 'SECRET-MIC-UID', 'Secret mic name', "
            "x'00', 'flac', 16000, 1, ?, 'test', ?, 1, 'test', ?, ?)",
            (str(uuid.uuid4()), status, stamp, stamp, stamp, day, text, stamp, stamp, stamp),
        )
        chunk_id = cursor.lastrowid
    con.close()
    return chunk_id


def add_label(path: Path, chunk_id: int, text: str | None, status: str = "accepted") -> None:
    con = db.connect(path, write=True)
    with db.write_transaction(con):
        con.execute(
            "INSERT INTO labels (chunk_id, text, status, teacher, teacher_prompt_version, created_at) "
            "VALUES (?, ?, ?, 'claude', 'teacher-v1', '2026-10-25T10:00:00.000Z')",
            (chunk_id, text, status),
        )
    con.close()


def rows(path: Path, sql: str, params=()) -> list[tuple]:
    con = sqlite3.connect(path)
    try:
        return con.execute(sql, params).fetchall()
    finally:
        con.close()


FAKE_TEACHER = r'''
import json, os, sys
from pathlib import Path

name = Path(sys.argv[0]).name
prompt = sys.stdin.read()
marker = "[irudd-voice-teacher-session]"
line = next(l for l in prompt[prompt.index(marker):].splitlines() if l.startswith('{"transcript": '))
transcript = json.loads(line)["transcript"]
cwd = Path.cwd()
with open(os.environ["FAKE_TEACHER_LOG"], "a") as log:
    log.write(json.dumps({"teacher": name, "argv": sys.argv[1:], "cwd": str(cwd),
                          "cwd_listing": sorted(os.listdir(cwd)), "stdin": prompt}) + "\n")
replies = json.loads(Path(os.environ["FAKE_TEACHER_REPLIES"]).read_text())
reply = replies.get(transcript, {"text": json.dumps({"cleaned": transcript})})
if reply.get("exit"):
    sys.exit(reply["exit"])

if name == "claude":
    out = {"type": "result", "subtype": "success", "is_error": False, "result": reply.get("text", ""),
           "total_cost_usd": 0.0125, "session_id": "fake",
           "usage": {"input_tokens": 12, "cache_creation_input_tokens": 300, "cache_read_input_tokens": 40,
                     "output_tokens": 25},
           "modelUsage": {"claude-fake-haiku": {"outputTokens": 1}, "claude-fake-opus": {"outputTokens": 24}}}
    if "structured" in reply:
        out["structured_output"] = reply["structured"]
    print(json.dumps(out))
else:
    events = [{"type": "thread.started", "thread_id": "fake"}, {"type": "turn.started"}]
    if reply.get("command"):
        events.append({"type": "item.started", "item": {"id": "item_0", "type": "command_execution",
                                                        "command": "ls", "status": "in_progress"}})
        events.append({"type": "item.completed", "item": {"id": "item_0", "type": "command_execution",
                                                          "command": "ls", "exit_code": 0, "status": "completed"}})
    events.append({"type": "item.completed", "item": {"id": "item_1", "type": "agent_message",
                                                      "text": reply.get("text", "")}})
    events.append({"type": "turn.completed",
                   "usage": {"input_tokens": 900, "cached_input_tokens": 100, "output_tokens": 30}})
    for event in events:
        print(json.dumps(event))
'''


class FakeTeachers:
    """`claude` and `codex` stubs on PATH that answer from a table:
    transcript → {"text": reply text, "structured": object, "command": true,
    "exit": code}. Unknown transcripts get {"cleaned": <transcript>}."""

    def __init__(self, folder: Path, monkeypatch):
        self.bin = folder / "bin"
        self.bin.mkdir()
        self.log = folder / "teacher-log.jsonl"
        self.replies_file = folder / "replies.json"
        self.replies: dict[str, dict] = {}
        for name in ("claude", "codex"):
            script = self.bin / name
            script.write_text(f"#!{sys.executable}\n{FAKE_TEACHER}")
            script.chmod(0o755)
        monkeypatch.setenv("PATH", f"{self.bin}{os.pathsep}{os.environ['PATH']}")
        monkeypatch.setenv("FAKE_TEACHER_LOG", str(self.log))
        monkeypatch.setenv("FAKE_TEACHER_REPLIES", str(self.replies_file))
        self.save()

    def reply(self, transcript: str, cleaned: str | None = None, **reply) -> None:
        if cleaned is not None:
            reply["text"] = json.dumps({"cleaned": cleaned})
        self.replies[transcript] = reply
        self.save()

    def save(self) -> None:
        self.replies_file.write_text(json.dumps(self.replies))

    def calls(self) -> list[dict]:
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines()]
