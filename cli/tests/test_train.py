"""Training examples and tokenizing. No real model needed."""

import json
import os
from pathlib import Path

import pytest

from irudd_voice import hardchecks, models, prompt, train


def test_reply_uses_the_prompt_escaping():
    assert train.reply_text('say "hi"\nit’s a/b') == '{"cleaned": "say \\"hi\\"\\nit’s a/b"}'
    assert json.loads(train.reply_text('a "b" \\ c')) == {"cleaned": 'a "b" \\ c'}


def test_example_is_the_app_prompt_plus_the_reply():
    row = train.example("um set it to five", "Set it to five.", ["SQLite"])
    assert row["messages"][:2] == prompt.messages("um set it to five", ["SQLite"])
    assert row["messages"][2] == {"role": "assistant", "content": '{"cleaned": "Set it to five."}'}


def test_tiny_examples_pass_the_hard_checks():
    rows = train.tiny_examples()
    assert len(rows) == 40
    assert rows == train.tiny_examples()  # same every run
    for row in rows:
        transcript = json.loads(row["messages"][1]["content"].split("\n\n")[0])["transcript"]
        cleaned = json.loads(row["messages"][2]["content"])["cleaned"]
        assert hardchecks.check(transcript, cleaned) == [], transcript


class FakeTokenizer:
    """Characters as tokens, enough to check offsets and special tokens."""

    def __init__(self, bos=None):
        self.bos_token = bos
        self.eos_token_id = 0
        self.calls = []

    def get_vocab(self):
        return {"<|im_end|>": 1}

    def apply_chat_template(self, messages, add_generation_prompt, tokenize, **options):
        self.calls.append(options)
        start = self.bos_token or ""
        return start + "".join(f"[{m['role']}]{m['content']}" for m in messages) + "[assistant]"

    def encode(self, text, add_special_tokens=True):
        return ([2] if add_special_tokens else []) + [ord(c) for c in text]


def test_tokenize_masks_the_prompt_and_ends_the_turn():
    tok = FakeTokenizer()
    row = train.example("hi", "Hi.")
    ids, offset = train.tokenize(tok, row, {"enable_thinking": False})
    assert tok.calls == [{"enable_thinking": False}]
    reply = '{"cleaned": "Hi."}'
    assert ids[offset:] == [ord(c) for c in reply] + [1]
    assert ids[0] == 2  # no BOS token: special tokens added, like mlx-lm's generate


def test_tokenize_adds_no_second_bos():
    tok = FakeTokenizer(bos="<bos>")
    ids, _ = train.tokenize(tok, train.example("hi", "Hi."), {})
    assert ids[0] == ord("<")


def test_tokenize_needs_a_reply():
    with pytest.raises(models.ModelError, match="assistant"):
        train.tokenize(FakeTokenizer(), {"messages": prompt.messages("hi")}, {})


def test_lora_keys_skip_gemma_kv_in_shared_layers():
    # Paths a layer lacks are skipped by mlx-lm, so listing k/v is harmless;
    # what matters is that q/o and the MLP are there for the KV-shared layers.
    assert {"self_attn.q_proj", "self_attn.o_proj", "mlp.down_proj"} <= set(train.LORA_KEYS["gemma4"])
    assert {"linear_attn.in_proj_qkv", "linear_attn.out_proj", "self_attn.q_proj"} <= set(train.LORA_KEYS["qwen3_5"])


def test_tiny_model_id():
    from datetime import date
    assert train.tiny_model_id(models.candidate("qwen3.5-2b"), date(2026, 10, 25)) == "qwen3.5-2b-tiny-20261025"


@pytest.mark.slow
@pytest.mark.skipif(not os.environ.get("IRUDD_VOICE_SLOW"), reason="real model; set IRUDD_VOICE_SLOW=1")
def test_tiny_lora_end_to_end(tmp_path):
    """Trains 4 LoRA steps on qwen3.5-2b, fuses, quantizes and checks the
    folder loads and still answers in the reply format."""
    from irudd_voice.generation import Model

    result = train.train_tiny(models.candidate("qwen3.5-2b"), tmp_path,
                              settings=train.LoraSettings(iterations=4, steps_per_report=2, steps_per_eval=4))
    assert models.verify(result.folder) == []
    manifest = result.manifest
    assert manifest["prompt_version"] == prompt.load()["version"]
    assert manifest["training"]["method"] == "lora" and manifest["training"]["iterations"] == 4
    gen = Model(result.folder).clean("um can you explain why the tests failed")
    assert hardchecks.parse_reply(gen.text, gen.hit_limit).cleaned is not None
