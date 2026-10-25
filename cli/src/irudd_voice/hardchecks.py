"""Hard checks: does a cleaned text keep what the speaker said?

The app (Swift) runs the same checks before pasting a model's reply, and
training's eval and the labeling tool run these. Both implementations must
agree on every case in shared/fixtures/hard-checks.json.

A check failing means "don't trust this output": the app pastes the raw
transcript instead, eval counts a failure, and labeling rejects the label.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass

# Words that start a reply rather than a cleaned-up request.
ANSWER_OPENERS = (
    "sure", "certainly", "of course", "absolutely", "here is", "here's", "here are",
    "i'd be happy", "i would be happy", "i can help", "i can't help", "as an ai",
    "great question", "the answer is", "to do this", "you can ",
)

# Correction markers: what the speaker says when replacing what came before.
CORRECTIONS = (
    "no", "sorry", "i mean", "actually", "rather", "wait", "scratch that", "not that",
    "make that", "or rather",
)

NEGATIONS = {
    "not", "never", "cannot", "without", "nothing", "nobody", "none", "neither", "nor",
    "don't", "doesn't", "didn't", "isn't", "aren't", "wasn't", "weren't", "can't",
    "won't", "wouldn't", "shouldn't", "couldn't", "haven't", "hasn't", "hadn't",
    "mustn't", "needn't", "dont", "doesnt", "didnt", "isnt", "arent", "cant", "wont",
}

# Words a cleanup may add without changing meaning.
FUNCTION_WORDS = {
    "a", "an", "the", "and", "or", "but", "to", "of", "in", "on", "at", "for", "with",
    "is", "are", "be", "it", "its", "it's", "this", "that", "these", "those", "then",
    "so", "as", "if", "do", "does", "please", "also", "s", "i", "you", "we",
}

CONTRACTIONS = {
    "don't": "do not", "doesn't": "does not", "didn't": "did not", "isn't": "is not",
    "aren't": "are not", "wasn't": "was not", "weren't": "were not", "can't": "can not",
    "cannot": "can not", "won't": "will not", "wouldn't": "would not",
    "shouldn't": "should not", "couldn't": "could not", "haven't": "have not",
    "hasn't": "has not", "hadn't": "had not", "it's": "it is", "that's": "that is",
    "there's": "there is", "what's": "what is", "let's": "let us", "i'm": "i am",
    "you're": "you are", "we're": "we are", "they're": "they are", "i've": "i have",
    "we've": "we have", "you've": "you have", "i'll": "i will", "we'll": "we will",
    "you'll": "you will", "i'd": "i would", "we'd": "we would",
}

NUMBER_WORDS = {
    "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
    "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
    "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
    "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
    "seventy": 70, "eighty": 80, "ninety": 90,
}
SCALES = {"hundred": 100, "thousand": 1000, "million": 1_000_000}

THINK_TAGS = ("<think>", "</think>")


@dataclass(frozen=True)
class Reply:
    """A parsed model reply: the cleaned text, or why it can't be used."""

    cleaned: str | None
    failure: str | None


def parse_reply(text: str, key: str = "cleaned") -> Reply:
    """Reads the model's raw reply. See shared/README.md, "Reading the reply"."""
    if any(tag in text for tag in THINK_TAGS):
        return Reply(None, "think_tags")
    stripped = text.strip()
    # Some models wrap JSON in a ``` fence; accept that, nothing else.
    fence = re.fullmatch(r"```(?:json)?\s*(.*?)\s*```", stripped, flags=re.S)
    if fence:
        stripped = fence.group(1).strip()
    try:
        value = json.loads(stripped)
    except json.JSONDecodeError:
        return Reply(None, "cut_off" if stripped.startswith("{") else "malformed")
    if not isinstance(value, dict) or not isinstance(value.get(key), str):
        return Reply(None, "malformed")
    return Reply(value[key].strip(), None)


def words(text: str) -> list[str]:
    """Lowercase words with apostrophes kept; punctuation and symbols split words."""
    text = text.lower().replace("’", "'")
    return re.findall(r"[a-z0-9]+(?:'[a-z]+)?", text)


def expanded(text: str) -> list[str]:
    out: list[str] = []
    for word in words(text):
        out.extend(CONTRACTIONS.get(word, word).split())
    return out


def numbers(text: str) -> list[int]:
    """Every number written as digits or spelled out (up to millions)."""
    found: list[int] = []
    tokens = words(text.replace(",", ""))
    current: int | None = None
    total = 0

    def flush() -> None:
        nonlocal current, total
        if current is not None:
            found.append(total + current)
        current, total = None, 0

    for token in tokens:
        if token.isdigit():
            flush()
            found.append(int(token))
        elif any(c.isdigit() for c in token):
            # Digits inside a word, like "T3" or "v2": count them too.
            flush()
            found.extend(int(run) for run in re.findall(r"[0-9]+", token))
        elif token in NUMBER_WORDS:
            value = NUMBER_WORDS[token]
            if current is not None and value < 10 and current % 10 == 0 and current >= 20:
                current += value  # "twenty five"
            elif current is not None:
                flush()
                current = value
            else:
                current = value
        elif token in SCALES and current is not None:
            if SCALES[token] == 100:
                current *= 100
            else:
                total += current * SCALES[token]
                current = 0
        elif token == "and" and current is not None:
            continue  # "one hundred and five"
        else:
            flush()
    flush()
    return found


def corrected_spans(text: str) -> set[int]:
    """Indexes of words the speaker replaced: the word(s) right before a
    correction marker ("fifteen, no, fifty" marks "fifteen")."""
    tokens = words(text)
    marked: set[int] = set()
    joined = " ".join(tokens)
    for marker in CORRECTIONS:
        for match in re.finditer(rf"(?:^| ){re.escape(marker)}(?= |$)", joined):
            index = joined[: match.start() + 1].count(" ") if match.start() else 0
            # Up to three words before the marker may be replaced.
            for back in range(1, 4):
                if index - back >= 0:
                    marked.add(index - back)
    return marked


IDENTIFIER = re.compile(
    r"[A-Za-z_][A-Za-z0-9_]*(?:[._/-][A-Za-z0-9_]+)+"  # dotted, slashed, snake, kebab
    r"|[a-z]+[A-Z][A-Za-z0-9]*"  # camelCase
    r"|[A-Z][a-z0-9]+[A-Z][A-Za-z0-9]*"  # PascalCase with a hump
    r"|[A-Za-z]+[0-9]+[A-Za-z0-9]*"  # letters then digits
)


def identifiers(text: str) -> list[str]:
    return [m.group(0) for m in IDENTIFIER.finditer(text)]


def _squash(text: str) -> str:
    return re.sub(r"[^a-z0-9]", "", text.lower())


def check(transcript: str, cleaned: str, vocabulary: list[str] | tuple[str, ...] = ()) -> list[str]:
    """Returns the names of the hard checks the cleaned text fails (empty = passes)."""
    failures: list[str] = []
    raw_words = words(transcript)
    out_words = words(cleaned)

    # Answered instead of cleaned: starts like a reply, or grew far beyond what was said.
    lead = cleaned.strip().lower()
    if any(lead.startswith(opener) for opener in ANSWER_OPENERS) and not any(
        transcript.strip().lower().startswith(opener) for opener in ANSWER_OPENERS
    ):
        failures.append("answers")
    elif len(out_words) > 1.6 * len(raw_words) + 8:
        failures.append("answers")

    # Numbers: nothing new, nothing kept by the speaker dropped.
    raw_numbers = numbers(transcript)
    out_numbers = numbers(cleaned)
    if any(n not in raw_numbers for n in out_numbers):
        failures.append("numbers")
    else:
        # Numbers the speaker kept: the transcript without corrected-away words.
        replaced = corrected_spans(transcript)
        kept_text = " ".join(w for i, w in enumerate(words(transcript.replace(",", ""))) if i not in replaced)
        if any(n not in out_numbers for n in set(numbers(kept_text))):
            failures.append("numbers")

    # Negations: the ones the speaker kept, no fewer and no more.
    replaced = corrected_spans(transcript)
    raw_negations = [w for i, w in enumerate(raw_words) if w in NEGATIONS and i not in replaced]
    out_negations = [w for w in out_words if w in NEGATIONS]
    if len(out_negations) != len(raw_negations):
        failures.append("negation")

    # Identifiers: each one written in the transcript must survive (ignoring case and separators).
    squashed_out = _squash(cleaned)
    for identifier in identifiers(transcript):
        if _squash(identifier) not in squashed_out:
            failures.append("identifiers")
            break

    # New words: anything that isn't in the transcript, the vocabulary, or a
    # small set of joining words. Numbers are checked above.
    allowed = set(expanded(transcript)) | FUNCTION_WORDS
    squashed_raw = _squash(transcript)
    for term in vocabulary:
        allowed.update(words(term))
    for word in expanded(cleaned):
        if word in allowed or word.isdigit() or word in NUMBER_WORDS or word in SCALES:
            continue
        if _stem(word) in {_stem(a) for a in allowed}:
            continue
        if word in squashed_raw:  # joined spoken parts, e.g. "read me" -> "readme"
            continue
        failures.append("new_words")
        break

    return failures


def _stem(word: str) -> str:
    for suffix in ("ing", "ed", "es", "s"):
        if word.endswith(suffix) and len(word) > len(suffix) + 2:
            return word[: -len(suffix)]
    return word
