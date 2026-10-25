"""Training examples and tokenizing. No real model needed."""

import json
import os

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


def test_train_dataset_uses_the_dataset_hash(tmp_path, monkeypatch):
    (tmp_path / "dataset.json").write_text(json.dumps({
        "dataset_hash": "abc", "prompt_version": prompt.load()["version"],
        "examples": {"train": 12, "selection": 2, "test": 3}, "augmented": {"train": 4}}))
    seen = {}
    monkeypatch.setattr(train, "train", lambda *args, **kwargs: seen.update(args=args, kwargs=kwargs))
    train.train_dataset(models.candidate("qwen3.5-2b"), tmp_path, "qwen3.5-2b-ft-1", models_dir=tmp_path)
    assert seen["args"][1:] == (tmp_path / "train.jsonl", tmp_path / "valid.jsonl", "qwen3.5-2b-ft-1")
    assert seen["kwargs"]["dataset_hash"] == "abc" and seen["kwargs"]["chunks"] == 8


def test_train_dataset_refuses_another_prompt_version(tmp_path):
    (tmp_path / "dataset.json").write_text(json.dumps({"dataset_hash": "abc", "prompt_version": "cleanup-v0",
                                                       "examples": {"train": 1}}))
    with pytest.raises(models.ModelError, match="cleanup-v0"):
        train.train_dataset(models.candidate("qwen3.5-2b"), tmp_path, "x", models_dir=tmp_path)
    with pytest.raises(models.ModelError, match="no dataset.json"):
        train.train_dataset(models.candidate("qwen3.5-2b"), tmp_path / "nope", "x", models_dir=tmp_path)


def test_dataset_examples_use_the_training_builder():
    from irudd_voice import dataset

    assert json.loads(dataset.example("um hi", "Hi.", ["SQLite"])) == train.example("um hi", "Hi.", ["SQLite"])


def test_bf16_estimate_counts_embeddings_once():
    # qwen3.5-2b: 3.76 GB of text weights, 1.02 GB of them embeddings; measured peak 6.7 GB.
    assert train.bf16_training_bytes(376, 102) == 650


def test_reply_loss_counts_only_reply_tokens():
    mx = pytest.importorskip("mlx.core")
    from mlx_lm.tuner.trainer import iterate_batches

    # 5 prompt tokens, then 3 reply tokens; the batch is padded with zeros.
    batch, lengths = next(iterate_batches([([11, 12, 13, 14, 15, 21, 22, 23], 5)], 1, 1024))
    targets = batch[:, 1:]
    mask = train.reply_mask(lengths, mx.arange(1, targets.shape[1] + 1))
    assert [t for t, m in zip(targets[0].tolist(), mask[0].tolist()) if m] == [21, 22, 23]


def test_training_replies_end_with_the_end_of_turn_token_not_end_of_text():
    class Tok:
        eos_token_id = 0

        def get_vocab(self):
            return {"<|endoftext|>": 248044, "<|im_end|>": 248046}

    assert train.end_of_turn_id(Tok()) == 248046
