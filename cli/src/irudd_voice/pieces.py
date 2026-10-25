"""Splits a long thought into pieces, the way the app does
(Packages/IruddVoiceKit/Sources/IruddVoiceKit/ThoughtPieces.swift). The app
cleans each piece on its own within the prompt's deadline and pastes the
cleaned pieces joined with a space, so `eval-compare` does the same.
Both sides run shared/fixtures/thought-pieces.json.

Pieces end at sentence ends where possible. A sentence longer than a piece
is split after a comma, semicolon, colon or dash, and a clause that's still
too long is cut at the word limit.
"""

from __future__ import annotations

from collections.abc import Callable

# The most words in one piece (ThoughtPieces.maxWords in the app).
MAX_WORDS = 120

# Closing quotes and brackets that can follow a sentence's last mark.
CLOSERS = frozenset("\"'”’)]")


def split(text: str, max_words: int = MAX_WORDS) -> list[str]:
    """The pieces of `text`, in order. A thought of `max_words` words or
    fewer is one piece: the text as it is, trimmed."""
    words = text.split()
    if len(words) <= max_words:
        trimmed = text.strip()
        return [trimmed] if trimmed else []
    # Units no longer than a piece: whole sentences, or the clauses (or
    # word-limit cuts) of a sentence that's too long.
    units: list[list[str]] = []
    for sentence in runs(words, ends_sentence):
        if len(sentence) <= max_words:
            units.append(sentence)
            continue
        for clause in runs(sentence, ends_clause):
            units.extend(clause[i:i + max_words] for i in range(0, len(clause), max_words))
    # Fill each piece with as many whole units as fit.
    pieces: list[list[str]] = []
    current: list[str] = []
    for unit in units:
        if current and len(current) + len(unit) > max_words:
            pieces.append(current)
            current = []
        current += unit
    if current:
        pieces.append(current)
    return [" ".join(piece) for piece in pieces]


def runs(words: list[str], ends_run: Callable[[str], bool]) -> list[list[str]]:
    """Splits `words` after each word where `ends_run` is true."""
    result: list[list[str]] = []
    current: list[str] = []
    for word in words:
        current.append(word)
        if ends_run(word):
            result.append(current)
            current = []
    if current:
        result.append(current)
    return result


def last_mark(word: str) -> str | None:
    return next((c for c in reversed(word) if c not in CLOSERS), None)


def ends_sentence(word: str) -> bool:
    return last_mark(word) in (".", "?", "!", "…")


def ends_clause(word: str) -> bool:
    if word in ("-", "–", "—"):
        return True
    return last_mark(word) in (",", ";", ":", "—", "–")
