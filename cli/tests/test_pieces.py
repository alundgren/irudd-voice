"""The shared thought-piece fixtures. The Swift app runs the same file."""

import json
from pathlib import Path

import pytest

from irudd_voice import pieces

SHARED = Path(__file__).resolve().parents[2] / "shared"
CASES = json.loads((SHARED / "fixtures/thought-pieces.json").read_text())["cases"]


def test_fixtures_are_there():
    assert len(CASES) >= 10
    assert len({c["name"] for c in CASES}) == len(CASES)


@pytest.mark.parametrize("case", CASES, ids=lambda c: c["name"])
def test_split(case):
    assert pieces.split(case["text"], case.get("max_words", pieces.MAX_WORDS)) == case["pieces"]
