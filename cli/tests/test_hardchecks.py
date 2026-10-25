"""The shared hard-check and prompt fixtures. The Swift app runs the same files."""

import json
from pathlib import Path

import pytest

from irudd_voice import hardchecks, prompt

SHARED = Path(__file__).resolve().parents[2] / "shared"
CHECKS = json.loads((SHARED / "fixtures/hard-checks.json").read_text())
PROMPTS = json.loads((SHARED / "fixtures/prompt-building.json").read_text())
SETTINGS = prompt.load()["checks"]


@pytest.mark.parametrize("case", CHECKS["replies"], ids=lambda c: c["name"])
def test_parse_reply(case):
    reply = hardchecks.parse_reply(case["reply"], hit_limit=case["hit_limit"])
    assert (reply.cleaned, reply.failure) == (case["cleaned"], case["failure"])


@pytest.mark.parametrize("case", CHECKS["checks"], ids=lambda c: c["name"])
def test_checks(case):
    result = hardchecks.check(case["transcript"], case["cleaned"], case["vocabulary"],
                              SETTINGS["max_output_words_ratio"], SETTINGS["max_output_words_slack"])
    assert result == case["failures"]


@pytest.mark.parametrize("case", PROMPTS["cases"], ids=lambda c: c["name"])
def test_prompt_bytes(case):
    system, user = prompt.messages(case["transcript"], case["terms"])
    assert system["content"] == case["system"]
    assert user["content"] == case["user"]


def test_input_json_is_valid_json():
    for case in PROMPTS["cases"]:
        assert json.loads(prompt.input_json(case["transcript"]))["transcript"] == case["transcript"]
