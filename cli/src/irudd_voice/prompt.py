"""Builds the cleanup prompt from shared/cleanup-prompt.json.

The Swift app builds byte-identical messages (shared/README.md, "Building
the prompt"; shared/fixtures/prompt-building.json), so a model trained on
these prompts sees the same text in the app.
"""

from __future__ import annotations

import json
import re
from functools import cache
from pathlib import Path

SHARED = Path(__file__).resolve().parents[3] / "shared"


@cache
def load(path: Path | None = None) -> dict:
    return json.loads((path or SHARED / "cleanup-prompt.json").read_text())


def json_string(text: str) -> str:
    """A JSON string literal with only the required escapes: quote,
    backslash and control characters. "/" and non-ASCII stay as they are."""
    out = ['"']
    for char in text:
        if char == '"':
            out.append('\\"')
        elif char == "\\":
            out.append("\\\\")
        elif char == "\n":
            out.append("\\n")
        elif char == "\r":
            out.append("\\r")
        elif char == "\t":
            out.append("\\t")
        elif char == "\b":
            out.append("\\b")
        elif char == "\f":
            out.append("\\f")
        elif ord(char) < 0x20:
            out.append(f"\\u{ord(char):04x}")
        else:
            out.append(char)
    out.append('"')
    return "".join(out)


def input_json(transcript: str) -> str:
    return '{"transcript": ' + json_string(transcript) + "}"


def fill(template: str, values: dict[str, str]) -> str:
    """Replaces {name} placeholders in one pass, so text inside a value
    (a transcript saying "{rule}") is never expanded."""
    return re.sub(r"\{(" + "|".join(map(re.escape, values)) + r")\}", lambda m: values[m.group(1)], template)


def messages(transcript: str, terms: list[str] | tuple[str, ...] = (), prompt: dict | None = None) -> list[dict]:
    """The chat messages for one cleanup."""
    prompt = prompt or load()
    used = list(terms)[: prompt["vocabulary_limit"]]
    system = prompt["system"]
    if used:
        system += fill(prompt["vocabulary_template"], {"terms": ", ".join(used)})
    user = fill(prompt["user_template"], {"input_json": input_json(transcript), "rule": prompt["rule"]})
    return [{"role": "system", "content": system}, {"role": "user", "content": user}]
