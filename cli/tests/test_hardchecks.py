"""The shared hard-check fixtures. The Swift app runs the same file."""

import json
from pathlib import Path

import pytest

from irudd_voice import hardchecks

FIXTURES = json.loads((Path(__file__).resolve().parents[2] / "shared/fixtures/hard-checks.json").read_text())


@pytest.mark.parametrize("case", FIXTURES["replies"], ids=lambda c: c["name"])
def test_parse_reply(case):
    reply = hardchecks.parse_reply(case["reply"])
    assert reply.cleaned == case["cleaned"]
    assert reply.failure == case["failure"]


@pytest.mark.parametrize("case", FIXTURES["checks"], ids=lambda c: c["name"])
def test_checks(case):
    assert hardchecks.check(case["transcript"], case["cleaned"], case["vocabulary"]) == case["failures"]
