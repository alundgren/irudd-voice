# Parity reference files

`irudd-voice parity-reference <model-dir> --out FILE` writes the greedy
tokens Python mlx-lm produces for the inputs in `evals/parity.jsonl`. The
Swift helper generates for the same inputs with the same model folder and
compares token by token.

## Inputs: `evals/parity.jsonl`

One JSON object per line:

```json
{"id": "p01", "transcript": "um can you explain why the tests failed", "vocabulary": []}
```

`vocabulary` is the list of terms passed to the prompt builder (may be
empty). Build the messages exactly as shared/README.md says.

## Output (format 1)

```json
{
 "format": 1,
 "model_id": "qwen3.5-2b-base-q4",
 "manifest_sha256": "<sha256 of the folder's manifest.json bytes>",
 "prompt_version": "cleanup-v1",
 "prompt_sha256": "<sha256 of shared/cleanup-prompt.json bytes>",
 "hardchecks_sha256": "<sha256 of hardchecks.py bytes followed by shared/fixtures/hard-checks.json bytes>",
 "inputs_sha256": "<sha256 of evals/parity.jsonl bytes>",
 "chat_template_options": {"enable_thinking": false},
 "max_new_tokens": 96,
 "stop_token_ids": [248046],
 "mlx_version": "0.32.4",
 "mlx_lm_version": "0.32.2",
 "items": [
  {
   "id": "p01",
   "transcript": "...",
   "vocabulary": [],
   "prompt": "<the chat-templated prompt string, exactly>",
   "prompt_token_ids": [248045, 8678, ...],
   "generated_token_ids": [4913, 76, ...],
   "stop_token_id": 248046,
   "text": "{\"cleaned\": \"Can you explain why the tests failed?\"}"
  }
 ]
}
```

- `prompt` is the output of the chat template with
  `add_generation_prompt` true and `chat_template_options` passed as
  template variables.
- `prompt_token_ids` is `prompt` tokenized. Special tokens are added only
  when the tokenizer has no BOS token or the prompt doesn't already start
  with it (mlx-lm's rule), so Gemma's `<bos>` appears once.
- Prefill: each item starts from an empty KV cache (no cache shared between
  items, no prompt cache file). mlx-lm's `generate_step` feeds the prompt
  in chunks of 2048 tokens; parity prompts are about 350 tokens, so the whole
  prompt goes through the model in one forward pass, and the first generated
  token is the argmax of the logits at the last prompt position. Each later
  token is fed back one at a time.
- Decoding is greedy (argmax of the logits at each step), no repetition
  penalty, no KV-cache quantization.
- `generated_token_ids` are the generated tokens **without** the stop token.
  Generation ends at the first token in `stop_token_ids` (that token goes in
  `stop_token_id`) or after `max_new_tokens` tokens (`stop_token_id` is
  null).
- `stop_token_ids` = the tokenizer's eos IDs, including those in
  `config.json` and `generation_config.json`, plus the chat template's
  end-of-turn token (`<|im_end|>`, `<turn|>` or `<end_of_turn>`, whichever is
  a single token in the vocabulary).
- `text` is `generated_token_ids` decoded with special tokens kept.

`prompt_sha256` and `hardchecks_sha256` say which prompt and hard checks the
file was made with; a Swift check can refuse a reference that doesn't match
its own copy of the shared files.

A Swift check should compare `prompt_token_ids` first (a difference there is
a prompt-building or tokenizer difference), then `generated_token_ids`, and
report the first index where they differ.
