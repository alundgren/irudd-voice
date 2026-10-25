"""Helpers for the train / eval-compare / promote tests: model folders
without real weights, frozen test thoughts and a fake judge on PATH."""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

from labeling import add_chunk

from irudd_voice import db, judge, models, prompt


def model_folder(models_dir: Path, model_id: str, candidate: str = "gemma-4-e2b", trained: bool = True,
                 dataset_hash: str = "dataset-1", db_path: Path | None = None) -> dict:
    """A folder that verifies (tokenizer.json, a weights file, manifest.json),
    recorded in `db_path` when given. Returns the manifest."""
    folder = models_dir / model_id
    folder.mkdir(parents=True)
    (folder / "tokenizer.json").write_text('{"fake": true}')
    (folder / "model.safetensors").write_bytes(model_id.encode())
    training = None
    if trained:
        training = {"method": "lora", "dataset_hash": dataset_hash, "chunks": 12,
                    "trained_at": "2026-10-25T12:00:00Z", "candidate": candidate}
    manifest = models.write_manifest(folder, model_id, models.candidate(candidate),
                                     prompt_version=prompt.load()["version"] if trained else None, training=training)
    if db_path:
        models.record(db_path, manifest)
    return manifest


def add_test_thought(path: Path, text: str, label: str, day: str = "2026-10-21") -> int:
    """A transcribed chunk on a test day with a frozen accepted label."""
    chunk_id = add_chunk(path, text, day)
    con = db.connect(path, write=True)
    with db.write_transaction(con):
        con.execute("INSERT OR IGNORE INTO dataset_days (local_day, split, assigned_at) "
                    "VALUES (?, 'test', '2026-10-25T10:00:00.000Z')", (day,))
        con.execute("INSERT INTO labels (chunk_id, text, status, teacher, teacher_prompt_version, frozen, created_at) "
                    "VALUES (?, ?, 'accepted', 'claude', 'teacher-v1', 1, '2026-10-25T10:00:00.000Z')",
                    (chunk_id, label))
    con.close()
    return chunk_id


def item(n: int, vote: str, cand_failures=(), inc_failures=()) -> dict:
    """One per-thought result as compare_items writes it."""
    return {
        "chunk_id": n,
        "candidate": {"cleaned": f"c{n}", "failures": list(cand_failures), "pasted": f"c{n}", "similarity": 1.0,
                      "seconds": 0.1},
        "incumbent": {"cleaned": f"i{n}", "failures": list(inc_failures), "pasted": f"i{n}", "similarity": 0.9,
                      "seconds": 0.1},
        "new_failures": sorted(set(cand_failures) - set(inc_failures)),
        "vote": vote,
        "picks": [],
        "judge_model": "fake",
        "judge_cost_usd": 0.0,
    }


def items(win=0, loss=0, tie=0, same=0, split=0, failed=0) -> list[dict]:
    outcomes = ([judge.WIN] * win + [judge.LOSS] * loss + [judge.TIE] * tie + [judge.SAME] * same
                + [judge.SPLIT] * split + [judge.FAILED] * failed)
    return [item(n, outcome) for n, outcome in enumerate(outcomes, 1)]


FAKE_JUDGE = r'''
import json, os, sys
from pathlib import Path

name = Path(sys.argv[0]).name
prompt = sys.stdin.read()
marker = "[irudd-voice-teacher-session]"
line = next(l for l in prompt[prompt.index(marker):].splitlines() if l.startswith('{"transcript": '))
data = json.loads(line)
cwd = Path.cwd()
with open(os.environ["FAKE_JUDGE_LOG"], "a") as log:
    log.write(json.dumps({"teacher": name, "argv": sys.argv[1:], "cwd": str(cwd),
                          "cwd_listing": sorted(os.listdir(cwd)), "stdin": prompt}) + "\n")
rules = json.loads(Path(os.environ["FAKE_JUDGE_RULES"]).read_text())
rule = rules.get(data["transcript"], rules.get("*", {}))
if rule.get("exit"):
    sys.exit(rule["exit"])
if "always" in rule:
    better = rule["always"]  # position bias: the same letter in both orders
elif "prefer" in rule:
    better = "A" if data["A"] == rule["prefer"] else "B" if data["B"] == rule["prefer"] else "tie"
else:
    better = "tie"
text = rule.get("text", json.dumps({"better": better}))
if name == "claude":
    print(json.dumps({"type": "result", "subtype": "success", "is_error": False, "result": text,
                      "total_cost_usd": 0.001, "usage": {"input_tokens": 10, "output_tokens": 5},
                      "modelUsage": {"claude-fake-judge": {"outputTokens": 5}}}))
else:
    for event in ({"type": "thread.started"}, {"type": "turn.started"},
                  {"type": "item.completed", "item": {"id": "item_1", "type": "agent_message", "text": text}},
                  {"type": "turn.completed", "usage": {"input_tokens": 10, "output_tokens": 5}}):
        print(json.dumps(event))
'''


class FakeJudge:
    """`claude` and `codex` stubs on PATH that vote by rule, per transcript
    ("*" for any): {"prefer": text} picks the output equal to text,
    {"always": "A"} picks A in both orders, {"exit": code} fails, {"text":
    raw reply}; no rule answers "tie"."""

    def __init__(self, folder: Path, monkeypatch):
        self.bin = folder / "judge-bin"
        self.bin.mkdir()
        self.log = folder / "judge-log.jsonl"
        self.rules_file = folder / "judge-rules.json"
        self.rules: dict[str, dict] = {}
        for name in ("claude", "codex"):
            script = self.bin / name
            script.write_text(f"#!{sys.executable}\n{FAKE_JUDGE}")
            script.chmod(0o755)
        monkeypatch.setenv("PATH", f"{self.bin}{os.pathsep}{os.environ['PATH']}")
        monkeypatch.setenv("FAKE_JUDGE_LOG", str(self.log))
        monkeypatch.setenv("FAKE_JUDGE_RULES", str(self.rules_file))
        self.save()

    def rule(self, transcript: str, **rule) -> None:
        self.rules[transcript] = rule
        self.save()

    def save(self) -> None:
        self.rules_file.write_text(json.dumps(self.rules))

    def calls(self) -> list[dict]:
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines()]
