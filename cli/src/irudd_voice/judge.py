"""Blind votes for `eval-compare`: which of two cleanups is better.

The judge is the teacher CLI that wrote the labels, run exactly like a
label call (teacher.call: empty temp folder, tools, MCP, hooks and session
saving off). It sees the raw transcript and two outputs, A and B, never
the label and never which model wrote which. Each pair is asked twice with
A and B swapped; the vote counts only when both answers pick the same
output.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from functools import cache
from pathlib import Path

from . import prompt, teacher

# Vote outcomes for one pair, from the candidate's side.
WIN, LOSS, TIE, SAME, SPLIT, FAILED = "win", "loss", "tie", "same", "split", "failed"
DECIDED = (WIN, LOSS)


@cache
def load(path: Path | None = None) -> dict:
    return json.loads((path or prompt.SHARED / "judge-prompt.json").read_text())


def schema_path(judge_prompt: dict | None = None) -> Path:
    return prompt.SHARED / (judge_prompt or load())["reply_schema"]


def prompt_sha256() -> str:
    """Binds a report to the judge prompt and reply schema it used."""
    digest = hashlib.sha256((prompt.SHARED / "judge-prompt.json").read_bytes())
    digest.update(schema_path().read_bytes())
    return digest.hexdigest()


def messages(transcript: str, a: str, b: str, terms: list[str] | tuple[str, ...] = (),
             judge_prompt: dict | None = None) -> tuple[str, str]:
    """(system, user) for one vote. The system message carries the cleanup
    rules and vocabulary, like the teacher's, then the checklist."""
    judge_prompt = judge_prompt or load()
    cleanup = prompt.load(prompt.SHARED / judge_prompt["cleanup_prompt"])
    cleanup_system = prompt.messages(transcript, terms, cleanup)[0]["content"]
    checklist = "\n".join(f"{n}. {item}" for n, item in enumerate(judge_prompt["checklist"], 1))
    system = (judge_prompt["system_before"] + cleanup_system
              + prompt.fill(judge_prompt["system_after"], {"checklist": checklist}))
    input_json = ('{"transcript": ' + prompt.json_string(transcript) + ', "A": ' + prompt.json_string(a)
                  + ', "B": ' + prompt.json_string(b) + "}")
    user = prompt.fill(judge_prompt["user_template"], {"marker": judge_prompt["marker"], "input_json": input_json})
    return system, user


def read_pick(text: str | None, structured: object = None) -> tuple[str | None, str | None]:
    value = teacher.read_object(text, structured, schema_path())
    return (value["better"], None) if value is not None else (None, "malformed")


def ask(judge: str, transcript: str, a: str, b: str, terms: list[str] | tuple[str, ...] = (),
        model: str | None = None) -> teacher.Answer:
    """One judge call; answer.cleaned is "A", "B" or "tie"."""
    system, user = messages(transcript, a, b, terms)
    return teacher.call(judge, system, user, schema_path(), read_pick, model)


@dataclass
class Vote:
    outcome: str  # WIN, LOSS, TIE, SAME, SPLIT or FAILED
    picks: list[str | None]  # per order: "candidate", "incumbent", "tie" or None (failed)
    cost_usd: float = 0.0
    model: str | None = None
    failure: str | None = None


def vote(judge: str, transcript: str, candidate: str, incumbent: str, terms: list[str] | tuple[str, ...] = (),
         model: str | None = None, ask_judge=ask) -> Vote:
    """Asks with the candidate as A, then as B. Identical outputs need no call."""
    if candidate == incumbent:
        return Vote(SAME, [])
    picks: list[str | None] = []
    cost = 0.0
    used_model = None
    for a, b, names in ((candidate, incumbent, ("candidate", "incumbent")),
                        (incumbent, candidate, ("incumbent", "candidate"))):
        answer = ask_judge(judge, transcript, a, b, terms, model)
        cost += answer.cost_usd or 0
        used_model = used_model or answer.model
        if answer.failure:
            return Vote(FAILED, picks + [None], cost, used_model, answer.failure)
        picks.append({"A": names[0], "B": names[1]}.get(answer.cleaned, "tie"))
    if picks[0] != picks[1]:
        outcome = SPLIT
    else:
        outcome = {"candidate": WIN, "incumbent": LOSS, "tie": TIE}[picks[0]]
    return Vote(outcome, picks, cost, used_model)
