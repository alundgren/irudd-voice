# Shared contracts

Files here are read by both the Swift app and the Python CLI. Change them
in one place, and bump the version when the meaning changes.

| File | What | Read by |
| --- | --- | --- |
| `cleanup-prompt.json` | The cleanup prompt and generation settings, versioned (`cleanup-v1`) | App (cleanup), CLI (train, eval, label) |
| `fixtures/hard-checks.json` | Cases every hard-check implementation must agree on | Swift and Python tests |
| `manifest.schema.md` | The model folder and `manifest.json` format | App, CLI |
| `vocabulary.schema.md` | The vocabulary file format | App, CLI |

## Building the prompt

1. `input_json` is `{"transcript": "<Apple's text>"}`, serialised with
   standard JSON escaping. Wrapping the text in JSON makes it read as data,
   not as a request to the model.
2. `vocabulary` is `vocabulary_template` with `{terms}` replaced by the
   vocabulary terms joined with `, `, or an empty string when there are none.
3. `rule` is repeated last on purpose: small models follow the most recent
   instruction most strongly.
4. Messages: `system` = `system`, `user` = the filled `user_template`. The
   chat template is applied with `chat_template_options` (thinking off).
5. Decode greedily (`temperature` 0) with `max_tokens`.

## Reading the reply

The reply must be one JSON object with a string `cleaned`. Anything else is
a failure, and the raw transcript is pasted instead:

- `think_tags`: the reply contains `<think>` or `</think>`.
- `cut_off`: the reply starts like JSON but doesn't parse (it ran out of tokens).
- `malformed`: no JSON object with a string `cleaned`.

Then the hard checks run on (`transcript`, `cleaned`, vocabulary). See
`fixtures/hard-checks.json` and `cli/src/irudd_voice/hardchecks.py`.
