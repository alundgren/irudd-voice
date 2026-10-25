"""Hard checks: does a cleaned text keep what the speaker said?

The app (Swift) runs the same checks before pasting a model's reply, and
training's eval and the labeling tool run these. Both implementations must
agree on every case in shared/fixtures/hard-checks.json; the exact rules are
written down in shared/README.md ("Hard checks").

A failing check means "don't trust this output": the app pastes the raw
transcript instead, eval counts a failure, and labeling rejects the label.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass

# The order failures are reported in. Fixtures compare lists exactly.
CHECK_ORDER = ("dropped", "answers", "question", "numbers", "negation", "identifiers", "new_words")

# Words that start a reply rather than a cleaned-up request.
ANSWER_OPENERS = (
    "sure", "certainly", "of course", "absolutely", "here is", "here's", "here are",
    "i'd be happy", "i would be happy", "i can help", "as an ai", "great question",
    "the answer is", "to do this", "you can",
)

# Said before the real content, or as padding. Ignored when comparing
# beginnings and when counting kept content.
FILLERS = {
    "um", "umm", "uh", "uhh", "er", "erm", "hmm", "so", "okay", "ok", "well", "like",
    "yeah", "alright", "basically", "just", "right", "actually", "you know", "i mean",
    "kind of", "sort of",
}

# Spoken corrections: "fifteen seconds, no, fifty seconds". A marker only
# counts when what follows restates what came before (see corrected_spans).
CORRECTION_MARKERS = ("no", "sorry", "i mean", "scratch that", "not that", "make that", "or rather")

NEGATIONS = {
    "no", "not", "never", "cannot", "without", "nothing", "nobody", "none", "neither", "nor",
    "don't", "doesn't", "didn't", "isn't", "aren't", "wasn't", "weren't", "can't", "won't",
    "wouldn't", "shouldn't", "couldn't", "haven't", "hasn't", "hadn't", "mustn't",
    "needn't", "dont", "doesnt", "didnt", "isnt", "arent", "cant", "wont",
}

# Words a cleanup may add without changing meaning.
FUNCTION_WORDS = {
    "a", "an", "the", "and", "or", "but", "to", "of", "in", "on", "at", "for", "with",
    "is", "are", "be", "it", "its", "this", "that", "these", "those", "then", "so", "as",
    "if", "do", "does", "please", "also", "s", "i", "you", "we",
}

# A spoken question has question word order: a helper verb then a pronoun
# ("can you", "is it"), or a question word then a helper verb ("why is",
# "how do"). "when the tests pass, merge it" is not a question.
HELPER_VERBS = {
    "can", "could", "would", "should", "is", "are", "was", "were", "do", "does", "did",
    "have", "has", "will", "shall", "may",
}
PRONOUNS = {"you", "i", "we", "it", "this", "that", "there", "they", "he", "she"}
QUESTION_WORDS = {"what", "why", "how", "when", "where", "which", "who"}

# Hedges a cleanup may drop; not counted as content for `dropped`.
HEDGES = {"maybe", "probably", "perhaps", "wondering", "whether", "trying", "say", "saying", "guess", "really"}

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
    "zero": 0, "oh": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
    "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
    "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
    "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
    "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
}
SCALES = {"hundred": 100, "thousand": 1000, "million": 1_000_000}

# Thinking markers: Qwen (<think>) and Gemma 4 (<|channel>thought … <channel|>, <|think|>).
THINK_TAGS = ("<think>", "</think>", "<|channel>", "<channel|>", "<|think|>")

STEM_SUFFIXES = ("ing", "ed", "es", "s")


@dataclass(frozen=True)
class Reply:
    """A parsed model reply: the cleaned text, or why it can't be used."""

    cleaned: str | None
    failure: str | None


def parse_reply(text: str, hit_limit: bool = False, key: str = "cleaned") -> Reply:
    """Reads the model's raw reply. `hit_limit` is true when generation
    stopped because it reached max_tokens."""
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
        return Reply(None, "cut_off" if hit_limit else "malformed")
    if not isinstance(value, dict) or not isinstance(value.get(key), str):
        return Reply(None, "malformed")
    return Reply(value[key].strip(), None)


# ---- Tokens ------------------------------------------------------------------


def words(text: str) -> list[str]:
    """Lowercase ASCII words; an apostrophe joins a following letter run
    ("don't"). Everything else (punctuation, symbols, non-ASCII letters)
    separates words."""
    text = text.lower().replace("’", "'")
    return re.findall(r"[a-z0-9]+(?:'[a-z]+)?", text)


def expand(tokens: list[str]) -> list[str]:
    out: list[str] = []
    for word in tokens:
        out.extend(CONTRACTIONS.get(word, word).split())
    return out


def stem(word: str) -> str:
    for suffix in STEM_SUFFIXES:
        if word.endswith(suffix) and len(word) > len(suffix) + 2:
            return word[: -len(suffix)]
    return word


def strip_fillers(tokens: list[str]) -> list[str]:
    """Drops leading filler words and two-word fillers ("you know")."""
    index = 0
    while index < len(tokens):
        if tokens[index] in FILLERS:
            index += 1
        elif index + 1 < len(tokens) and f"{tokens[index]} {tokens[index + 1]}" in FILLERS:
            index += 2
        else:
            break
    return tokens[index:]


# ---- Numbers -----------------------------------------------------------------


def numbers_in(tokens: list[str]) -> list[int]:
    """Every number written as digits, digits inside a word ("T3"), or spelled
    out ("one thousand two hundred", "a hundred", "twenty five")."""
    found: list[int] = []
    total = 0  # completed thousands/millions
    current: int | None = None  # the part under the current scale

    def flush() -> None:
        nonlocal total, current
        if current is not None or total:
            found.append(total + (current or 0))
        total, current = 0, None

    for index, token in enumerate(tokens):
        if token.isdigit():
            flush()
            found.append(int(token))
        elif any(c.isdigit() for c in token):
            flush()
            found.extend(int(run) for run in re.findall(r"[0-9]+", token))
        elif token in NUMBER_WORDS and not (token == "oh" and current is None and not total):
            value = NUMBER_WORDS[token]
            if current is not None and current % 100 >= 20 and current % 10 == 0 and value < 10:
                current += value  # "twenty five", "two hundred twenty five"
            elif current is not None and current % 100 == 0 and current >= 100 and value < 100:
                current += value  # "one hundred five"
            elif current is None and total and value < 1000:
                current = value  # "one thousand two …"
            elif current is not None:
                flush()
                current = value
            else:
                current = value
        elif token in SCALES:
            scale = SCALES[token]
            if current is None and not total and index > 0 and tokens[index - 1] in ("a", "one"):
                current = 1  # "a hundred"
            if current is None and not total:
                continue
            if scale == 100:
                current = (current or 1) * 100
            else:
                total += (current or 1) * scale
                current = None
        elif token == "and" and (current is not None or total):
            continue  # "one hundred and five"
        else:
            flush()
    flush()
    return found


def match_numbers(kept: list[int], out: list[int]) -> tuple[list[int], list[int]]:
    """Pairs the speaker's kept numbers with the output's numbers. Walking the
    kept numbers in order, each one is matched to an equal output number, or
    else a run of 2 to 6 consecutive kept numbers is matched to an output
    number whose digits are those numbers joined ("eight zero eight zero" or
    "eighty eighty" = 8080). Both sides are used up whole. Returns (kept
    numbers left unmatched, output numbers left unmatched)."""
    left = list(out)
    unmatched: list[int] = []
    index = 0
    while index < len(kept):
        if kept[index] in left:
            left.remove(kept[index])
            index += 1
            continue
        joined = str(kept[index])
        for end in range(index + 1, min(index + 6, len(kept))):
            joined += str(kept[end])
            if int(joined) in left:
                left.remove(int(joined))
                index = end + 1
                break
        else:
            unmatched.append(kept[index])
            index += 1
    return unmatched, left


# ---- Corrections -------------------------------------------------------------


def _kind(token: str) -> str:
    if token.isdigit() or token in NUMBER_WORDS:
        return "number"
    return "word"


def corrected_spans(tokens: list[str]) -> tuple[set[int], set[int]]:
    """Finds spoken corrections. Returns (replaced word indexes, marker word
    indexes). A marker counts only when the next word restates something from
    the three words before it: the same word, or a number after a number.
    "fifteen seconds no fifty seconds" replaces "fifteen seconds"; "there is
    no cache" is not a correction."""
    replaced: set[int] = set()
    markers: set[int] = set()
    for index in range(len(tokens)):
        for marker in CORRECTION_MARKERS:
            parts = marker.split()
            if tokens[index:index + len(parts)] != parts:
                continue
            before = tokens[max(0, index - 3):index]
            after = tokens[index + len(parts):index + len(parts) + 4]
            if not before or not after:
                continue
            restated = any(w in before for w in after if w not in FUNCTION_WORDS) or (
                _kind(after[0]) == "number" and any(_kind(w) == "number" for w in before)
            )
            if restated:
                replaced.update(range(max(0, index - 3), index))
                markers.update(range(index, index + len(parts)))
    return replaced, markers


# ---- Identifiers -------------------------------------------------------------

IDENTIFIER = re.compile(
    r"[A-Za-z_][A-Za-z0-9_]*(?:[._/-][A-Za-z0-9_]+)+"  # dotted, slashed, snake, kebab
    r"|[a-z]+[A-Z][A-Za-z0-9]*"  # camelCase
    r"|[A-Z][a-z0-9]+[A-Z][A-Za-z0-9]*"  # PascalCase with a hump
    r"|[A-Za-z]+[0-9]+[A-Za-z0-9]*"  # letters then digits
)


def identifiers(text: str) -> list[str]:
    return [m.group(0) for m in IDENTIFIER.finditer(text)]


def squash(text: str) -> str:
    return re.sub(r"[^a-z0-9]", "", text.lower())


# ---- The checks --------------------------------------------------------------


def check(
    transcript: str,
    cleaned: str,
    vocabulary: list[str] | tuple[str, ...] = (),
    max_words_ratio: float = 1.6,
    max_words_slack: int = 8,
) -> list[str]:
    """Returns the names of the hard checks the cleaned text fails, in
    CHECK_ORDER (empty = passes)."""
    failures: set[str] = set()
    raw = words(transcript)
    out = words(cleaned)
    raw_expanded = expand(raw)
    out_expanded = expand(out)
    replaced, markers = corrected_spans(raw)
    ignored = replaced | markers

    # dropped: nothing (or too little) left of what the speaker kept.
    filler_pairs = {
        i + k for i in range(len(raw) - 1) if f"{raw[i]} {raw[i + 1]}" in FILLERS for k in (0, 1)
    }
    content = [
        w for i, w in enumerate(raw)
        if i not in ignored and i not in filler_pairs and w not in FUNCTION_WORDS
        and w not in FILLERS and w not in HEDGES
        and _kind(w) != "number" and w not in SCALES  # numbers are checked on their own
    ]
    out_stems = {stem(w) for w in out_expanded}
    if content and not out:
        failures.add("dropped")
    elif len(content) >= 4:
        kept = sum(1 for w in content if stem(w) in out_stems or w in squash(cleaned))
        if kept / len(content) < 0.5:
            failures.add("dropped")

    # answers: starts like a reply (not just echoing how the speaker began), or grew too much.
    lead = strip_fillers(out)
    raw_lead = strip_fillers(raw)[:4]
    for opener in ANSWER_OPENERS:
        opener_words = words(opener)
        if lead[: len(opener_words)] == opener_words:
            joined = " ".join(raw_lead)
            if " ".join(opener_words) not in joined:
                failures.add("answers")
            break
    if len(out) > max_words_ratio * len(raw) + max_words_slack:
        failures.add("answers")

    # question: a spoken question must stay a question.
    head = strip_fillers(raw)[:2]
    asks = len(head) == 2 and (
        (head[0] in HELPER_VERBS and head[1] in PRONOUNS)
        or (head[0] in QUESTION_WORDS and head[1] in HELPER_VERBS)
    )
    if asks and out and not cleaned.rstrip().endswith("?"):
        failures.add("question")

    # numbers: exactly the numbers the speaker kept (corrected-away ones don't count).
    kept_numbers = numbers_in([w for i, w in enumerate(raw) if i not in ignored])
    missing, extra = match_numbers(kept_numbers, numbers_in(out))
    if missing or extra:
        failures.add("numbers")

    # negation: the negations the speaker kept, no fewer and no more.
    raw_negations = sum(1 for i, w in enumerate(raw) if w in NEGATIONS and i not in ignored)
    out_negations = sum(1 for w in out if w in NEGATIONS)
    if raw_negations != out_negations:
        failures.add("negation")

    # identifiers: each one written in the transcript survives (ignoring case and separators).
    squashed_out = squash(cleaned)
    if any(squash(identifier) not in squashed_out for identifier in identifiers(transcript)):
        failures.add("identifiers")

    # new_words: every word is from the transcript, the vocabulary, a small set of
    # joining words, or 2–3 consecutive transcript words joined ("read me" → "readme").
    allowed = set(raw_expanded) | FUNCTION_WORDS
    for term in vocabulary:
        allowed.update(words(term))
    allowed_stems = {stem(a) for a in allowed}
    joins = {
        "".join(raw_expanded[i:i + n]) for n in (2, 3) for i in range(len(raw_expanded) - n + 1)
    }
    for word in out_expanded:
        if word in allowed or stem(word) in allowed_stems or word in joins:
            continue
        if word.isdigit() or word in NUMBER_WORDS or word in SCALES:
            continue  # numbers are checked above
        failures.add("new_words")
        break

    return [name for name in CHECK_ORDER if name in failures]
