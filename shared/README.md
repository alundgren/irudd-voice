# Shared contracts

Files here are read by both the Swift app and the Python CLI. Change them
in one place and bump the version when the meaning changes. Both sides have
tests that run the fixtures in `fixtures/`.

| File | What | Read by |
| --- | --- | --- |
| `cleanup-prompt.json` | Cleanup prompt, generation and check settings (`cleanup-v1`) | App (cleanup), CLI (train, eval, label) |
| `fixtures/prompt-building.json` | Exact system and user messages for given inputs | Swift and Python tests |
| `fixtures/hard-checks.json` | Reply parsing and hard-check results every implementation must match | Swift and Python tests |
| `manifest.schema.md` | Model folders and `manifest.json` | App, CLI |
| `vocabulary.schema.md` | `vocabulary.json` | App, CLI |
| `app-state.md` | Keys the app and CLI use to coordinate through the database | App, CLI |

Reference implementations: `cli/src/irudd_voice/prompt.py` and
`cli/src/irudd_voice/hardchecks.py`.

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
   `<channel|>`, `<|think|>` → `think_tags`.
2. Trim whitespace. If the whole reply is a ``` fence (optionally
   ```` ```json ````), take what's inside it, trimmed.
3. If that doesn't parse as JSON: `cut_off` when generation stopped at
   `max_tokens`, otherwise `malformed`. Trailing text after the object
   doesn't parse, so it's `malformed`.
4. If it isn't an object with a string under `output_key` → `malformed`.
5. Otherwise the cleaned text is that string, trimmed.

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
appears before it. If it is, the words before are *replaced* and the marker
words are *markers*. Both are *ignored* below.

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
  helper verb then a pronoun (`can you`, `is it`), or a question word then
  a helper verb (`why is`, `how do`), and the output doesn't end with `?`.
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
