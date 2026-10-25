# Shared contracts

Files here are read by both the Swift app and the Python CLI. Change them
in one place and bump the version when the meaning changes. Both sides have
tests that run the fixtures in `fixtures/`.

| File | What | Read by |
| --- | --- | --- |
| `cleanup-prompt.json` | Cleanup prompt, generation and check settings (`cleanup-v1`) | App (cleanup), CLI (train, eval, label) |
| `teacher-prompt.json` | Labeling prompt for Claude Code and Codex (`teacher-v1`); wraps the cleanup rules | CLI (label) |
| `teacher-reply.schema.json` | JSON schema of a teacher's reply, `{"cleaned": "..."}` | CLI (label), passed to the teacher CLIs |
| `judge-prompt.json` | Blind-vote prompt for `eval-compare` (`judge-v1`); wraps the cleanup rules and a fixed checklist | CLI (eval-compare) |
| `judge-reply.schema.json` | JSON schema of a judge's reply, `{"better": "A" \| "B" \| "tie"}` | CLI (eval-compare), passed to the teacher CLIs |
| `fixtures/prompt-building.json` | Exact system and user messages for given inputs | Swift and Python tests |
| `fixtures/hard-checks.json` | Reply parsing and hard-check results every implementation must match | Swift and Python tests |
| `fixtures/thought-pieces.json` | How a long thought is split into pieces before cleanup | Swift and Python tests |
| `manifest.schema.md` | Model folders and `manifest.json` | App, CLI |
| `vocabulary.schema.md` | `vocabulary.json` | App, CLI |
| `app-state.md` | Keys the app and CLI use to coordinate through the database | App, CLI |

Reference implementations: `cli/src/irudd_voice/prompt.py` and
`cli/src/irudd_voice/hardchecks.py`.

## Building the teacher prompt

`irudd-voice label` builds the teacher's messages from `teacher-prompt.json`
and the cleanup prompt it names (`cli/src/irudd_voice/teacher.py`):

- **System** = `system_before` + the cleanup system message (rules plus
  vocabulary, built as below) + `system_after`.
- **User** = `user_template` with `{marker}`, `{input_json}` (as below) and
  `{rule}` (the cleanup rule) filled in one pass. The marker lets
  `irudd-voice vocab` skip any log a teacher run leaves.

Bump `version` when the meaning changes; each label row stores it.

## Building the judge prompt

`irudd-voice eval-compare` asks the teacher CLI that wrote the labels which
of two outputs is better (`cli/src/irudd_voice/judge.py`), with the same
contained run as a label:

- **System** = `system_before` + the cleanup system message (rules plus
  vocabulary) + `system_after` with `{checklist}` = the `checklist` items
  numbered `1. ` … one per line.
- **User** = `user_template` with `{marker}` and `{input_json}` filled in
  one pass. `input_json` is `{"transcript": ` + literal + `, "A": ` +
  literal + `, "B": ` + literal + `}`, with the string escaping below. The
  label is never shown.

Each pair is asked twice with A and B swapped. A vote counts only when both
answers pick the same output. Reports store `judge_prompt_sha256` (SHA-256 of
this file's bytes, then the reply schema's), so `promote` refuses a report
made with another judge prompt.

## Building the prompt

1. **Vocabulary** goes in the system message, so the system message (rules
   plus vocabulary) stays the same between requests and can be cached. Take
   the first `vocabulary_limit` terms in file order. If there are any,
   append `vocabulary_template` with `{terms}` = the terms joined by `", "`.
   If there are none, append nothing.
2. **`input_json`** is exactly `{"transcript": ` + string literal + `}`.
   The string literal escapes only `"` → `\"`, `\` → `\\`, newline → `\n`,
   carriage return → `\r`, tab → `\t`, backspace → `\b`, form feed → `\f`,
   and other characters below U+0020 → `\u00XX` (lowercase hex). `/` and
   non-ASCII characters are written as they are. This is not the default
   output of Python's `json.dumps` or Swift's `JSONEncoder`; use the
   hand-written escaper.
3. **User message** = `user_template` with `{input_json}` and `{rule}`
   replaced **in a single pass**, so a transcript containing `{rule}` is
   left alone.
4. Messages are `[system, user]`. Apply the model's chat template with
   `add_generation_prompt` true and `chat_template_options` (thinking off).
5. Decode greedily (`temperature` 0), at most `max_tokens` tokens, and stop
   at the model's end-of-turn tokens (Gemma lists them in
   `generation_config.json`).

## Reading the reply

Work through these in order:

1. If the reply contains any of `<think>`, `</think>`, `<|channel>`,
   `<channel|>`, `<|think|>` → `think_tags`. Search the UTF-8 bytes (or
   code points), not user-perceived characters: `<think>` followed by a
   combining mark still counts.
2. Trim whitespace. If the whole reply is a ``` fence (optionally
   ```` ```json ````), take what's inside it, trimmed.
3. If that doesn't parse as strict JSON (below): `cut_off` when generation
   stopped at `max_tokens`, otherwise `malformed`. Trailing text after the
   object doesn't parse, so it's `malformed`.
4. If it isn't an object with a string under `output_key` → `malformed`.
5. Otherwise the cleaned text is that string, trimmed.

**Whitespace** is exactly the characters Python's `str.isspace()` accepts,
which `str.strip()` trims and the fence pattern's `\s` matches: U+0009–U+000D,
U+001C–U+001F, U+0020, U+0085, U+00A0, U+1680, U+2000–U+200A, U+2028,
U+2029, U+202F, U+205F, U+3000. Zero-width space (U+200B) and the byte order
mark (U+FEFF) are not whitespace.

**Strict JSON** is RFC 8259 JSON as Python's `json.loads` reads it (raw
control characters inside strings refused), and also refuses:

- a key repeated in any object (keys compare by code points, so `café`
  written two ways is two keys);
- the constants `NaN`, `Infinity` and `-Infinity`;
- a byte order mark before the JSON;
- an escaped lone surrogate (`"\ud800"`, `"\udc00"`); an escaped pair
  (`"\ud83d\ude00"`) is one character;
- objects and arrays nested more than 100 deep (the top-level value is
  depth 1).

Numbers only have to match the grammar; their values don't matter.

Any failure means the raw transcript is pasted instead.

## Hard checks

`check(transcript, cleaned, vocabulary)` returns the failing check names,
in this order: `dropped`, `answers`, `question`, `numbers`, `negation`,
`identifiers`, `new_words`. Use the same `vocabulary` terms as the prompt
(the first `vocabulary_limit`).

**Words.** Lowercase, map `’` to `'`, then take the matches of
`[a-z0-9]+(?:'[a-z]+)?`. Everything else separates words, including
non-ASCII letters. *Expanded words* replace contractions with their long
form (table `CONTRACTIONS`). The *stem* of a word removes the first
matching suffix of `ing`, `ed`, `es`, `s` when the word is more than two
letters longer than the suffix.

**Corrections.** At each position where a correction marker starts
(`no`, `sorry`, `i mean`, `scratch that`, `not that`, `make that`,
`or rather`), take up to 3 words *before* and up to 4 words *after* it. It's a
correction only if some word after it (that isn't a joining word) also
appears before it, or the first word after it is a number and a number
appears before it. If it is, the marker words are *markers*, and the words
before it are *replaced* starting at the earliest of: a word before that is
restated after (not a joining word), and, when the first word after is a
number, the first number before. The replaced words run from there up to the
marker, never the whole 3-word window, so `don't run five, no, six tests`
replaces only `five` and keeps `don't`. Replaced and marker words are
*ignored* below.

**Numbers** (`numbers_in`, applied to a word list). Walk the words keeping
`total` (completed thousands/millions) and `current` (the part below the
current scale, or none). "Flush" appends `total + (current or 0)` if either
is set, then resets both.

- A word of digits: flush, then append its value.
- A word with digits inside (`t3`, `v2`): flush, then append each digit run.
- A number word (`NUMBER_WORDS`; `oh` only when `current` or `total` is set):
  - if `current` is set, `current % 100 >= 20`, `current % 10 == 0` and the
    value is below 10: add it (`twenty five`, `two hundred twenty five`);
  - else if `current` is set, `current >= 100`, `current % 100 == 0` and the
    value is below 100: add it (`two hundred twenty`);
  - else if `current` is not set, `total` is set and the value is below 1000:
    `current` = value (`one thousand two …`);
  - else if `current` is set: flush, then `current` = value;
  - else `current` = value.
- A scale word (`hundred`, `thousand`, `million`): if nothing is set and the
  previous word is `a` or `one`, `current` = 1. If still nothing is set,
  ignore the word. `hundred`: `current` = (`current` or 1) × 100. Otherwise
  `total` += (`current` or 1) × scale, and `current` is unset.
- `and` while something is set: skip it.
- Any other word: flush.
- Flush at the end.

**Matching numbers** (`match_numbers(kept, out)`). `kept` are the numbers in
the transcript with ignored words blanked out (blank, not removed, so
positions stay), each with its word span from `numbers_with_positions`.
Compare numbers as decimal strings.

1. Joined runs first. For run length L from min(6, count) down to 2, and
   for each start from left to right: skip runs touching a used kept
   number. Skip runs where some number doesn't start on the word right
   after the previous one ended (numbers must be spoken back to back:
   `eight zero eight zero`, not `one minute thirty`). Join the run's
   decimal strings. If an unused output number equals it, use up both.
2. Then each remaining kept number, in order, uses up an equal output
   number, or is unmatched.
3. Fail `numbers` if any kept number or any output number is left.

In the scale step, "`current` or 1" means 1 only when `current` is unset; a
`current` of 0 stays 0.

**Big numbers.** Numbers are compared as decimal strings without leading
zeros (`007` → `7`), and digit strings have no length limit. A spelled-out
number can't pass 2^53 (9007199254740992): if a scale word would make
`current` or `total` larger, the number ends at that word and is
*unusable*. The same goes for a number whose final `total + current` is
over 2^53. An unusable number matches nothing: it isn't joined into runs
and is always left over, so it fails `numbers` on either side. (A 64-bit
implementation can treat an overflowing multiplication as "over 2^53".)

**Fillers.** `FILLERS` words anywhere, and two-word fillers (`you know`,
`kind of`, …) wherever both words appear together, don't count as content.
`strip_fillers` removes them from the start only.

The checks:

- `dropped`: the transcript has content words (not ignored, not joining
  words, not fillers, not hedges, not number or scale words) and the output
  has no words. Or there
  are at least 4 content words and fewer than half appear in the output
  (by stem, or inside the output with separators removed).
- `answers`: after removing leading fillers, the output starts with an
  answer opener (`ANSWER_OPENERS`) that isn't among the transcript's first 4
  words after its own fillers. Or the output has more than
  `max_output_words_ratio` × transcript words + `max_output_words_slack` words.
- `question`: after leading fillers, the transcript's first two words are a
  helper verb (`HELPER_VERBS`) then a pronoun (`PRONOUNS`: `can you`,
  `is it`), or a question word (`QUESTION_WORDS`) then a helper verb
  (`why is`, `how do`), and the output's last code point after trimming
  trailing whitespace isn't `?`. When the helper verb is `do` or `have`, the
  second word must be a person (`PERSONS`: `you`, `i`, `we`, `they`, `he`,
  `she`), not just any pronoun: `do you…` is a question, `do it now` and
  `have it run on CI` are commands.
- `numbers`: `match_numbers(numbers in the transcript's non-ignored words,
  numbers in the output)` leaves anything unmatched on either side. So a
  corrected-away number in the output fails, as does a dropped or changed one.
- `negation`: the number of negation words (`NEGATIONS`, including `no`)
  differs between the output and the transcript's non-ignored words.
- `identifiers`: an identifier written in the transcript (dotted, slashed,
  snake, kebab, camelCase, PascalCase with a hump, letters followed by
  digits) doesn't appear in the output after lowercasing and removing
  everything but letters and digits.
- `new_words`: an expanded output word isn't a transcript word, a
  vocabulary word, a joining word, the same stem as one of those, 2–3
  consecutive transcript words joined (`read me` → `readme`), or a number.

The word lists are in `hardchecks.py`; copy them exactly.
