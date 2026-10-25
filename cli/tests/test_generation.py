"""Greedy generation's stop logic and the parity file, with fakes for MLX."""

import hashlib
import json

from irudd_voice import generation, parity, prompt
from irudd_voice.generation import Generation, Model


class FakeMx:
    def array(self, ids):
        return list(ids)

    def argmax(self, logits, axis=-1):
        return logits

    def clear_cache(self):
        pass


class FakeTokenizer:
    bos_token = None

    def __init__(self, eos_ids=(7,), eos_id=7, vocab=None):
        self.eos_token_ids = set(eos_ids)
        self.eos_token_id = eos_id
        self._vocab = vocab or {}

    def get_vocab(self):
        return self._vocab

    def decode(self, ids):
        return "".join(chr(ord("a") + i) for i in ids)


def model_with(tokens, stop_ids):
    """A Model whose generate_step yields `tokens`, at most max_tokens of them."""
    model = object.__new__(Model)
    model._mx = FakeMx()
    model.model = None
    model.tokenizer = FakeTokenizer()
    model.stop_ids = set(stop_ids)
    model.calls = []

    def generate_step(prompt_ids, _model, max_tokens, sampler):
        model.calls.append((prompt_ids, max_tokens, sampler(3)))
        for token in tokens[:max_tokens]:
            yield token, None

    model._generate_step = generate_step
    return model


def test_generation_stops_at_a_stop_token_and_leaves_it_out():
    model = model_with([0, 1, 9, 2], stop_ids={9})
    gen = model.generate([5, 6], max_tokens=10)
    assert (gen.token_ids, gen.stop_token_id, gen.text, gen.hit_limit) == ([0, 1], 9, "ab", False)
    assert model.calls == [([5, 6], 10, 3)]  # greedy: the sampler is argmax


def test_generation_at_the_limit_reports_hit_limit():
    gen = model_with([0, 1, 2, 3], stop_ids={9}).generate([5], max_tokens=3)
    assert (gen.token_ids, gen.stop_token_id, gen.hit_limit) == ([0, 1, 2], None, True)


def test_a_stop_token_as_the_last_allowed_token_is_a_stop():
    gen = model_with([0, 1, 9], stop_ids={9}).generate([5], max_tokens=3)
    assert (gen.token_ids, gen.stop_token_id, gen.hit_limit) == ([0, 1], 9, False)


def test_stop_token_ids_add_end_of_turn():
    gemma = FakeTokenizer(eos_ids={1, 106, 50}, eos_id=1, vocab={"<turn|>": 106, "<|turn>": 105})
    assert generation.stop_token_ids(gemma) == {1, 50, 106}
    qwen = FakeTokenizer(eos_ids=set(), eos_id=248046, vocab={"<|im_end|>": 248046, "<|endoftext|>": 248044})
    assert generation.stop_token_ids(qwen) == {248046}
    other = FakeTokenizer(eos_ids={2}, eos_id=None, vocab={"<end_of_turn>": 3})
    assert generation.stop_token_ids(other) == {2, 3}


def test_contract_hashes_cover_the_prompt_and_checks():
    hashes = generation.contract_hashes()
    shared = prompt.SHARED
    assert hashes["prompt_sha256"] == hashlib.sha256((shared / "cleanup-prompt.json").read_bytes()).hexdigest()
    assert len(hashes["hardchecks_sha256"]) == 64
    assert generation.hardware()


class FakeModel:
    def __init__(self, folder):
        self.manifest = json.loads((folder / "manifest.json").read_text())
        self.prompt = prompt.load()
        self.stop_ids = {9, 4}

    def prompt_text(self, transcript, terms):
        return f"<{transcript}|{','.join(terms)}>"

    def encode(self, text):
        return [len(text), 1]

    def generate(self, ids, max_tokens):
        assert max_tokens == parity.MAX_NEW_TOKENS
        return Generation([3, 2], 9, '{"cleaned": "x"}', 0.01)


def test_parity_file_fields(tmp_path, monkeypatch):
    folder = tmp_path / "m"
    folder.mkdir()
    (folder / "manifest.json").write_text('{"schema": 1, "id": "m"}')
    monkeypatch.setattr(parity, "Model", FakeModel)
    result = parity.reference(folder, log=lambda _: None)
    assert result["format"] == 1 and result["model_id"] == "m"
    assert result["manifest_sha256"] == hashlib.sha256(b'{"schema": 1, "id": "m"}').hexdigest()
    assert result["inputs_sha256"] == hashlib.sha256(parity.DEFAULT_INPUTS.read_bytes()).hexdigest()
    assert {k: result[k] for k in ("prompt_sha256", "hardchecks_sha256")} == generation.contract_hashes()
    assert result["prompt_version"] == "cleanup-v1" and result["max_new_tokens"] == 96
    assert result["stop_token_ids"] == [4, 9]
    assert result["chat_template_options"] == {"enable_thinking": False}
    assert len(result["items"]) == 20
    first = result["items"][0]
    assert set(first) == {"id", "transcript", "vocabulary", "prompt", "prompt_token_ids", "generated_token_ids",
                          "stop_token_id", "text"}
    assert first["prompt"] == f"<{first['transcript']}|>"
    assert (first["generated_token_ids"], first["stop_token_id"]) == ([3, 2], 9)
    with_terms = next(i for i in result["items"] if i["vocabulary"])
    assert with_terms["prompt"].endswith(",".join(with_terms["vocabulary"]) + ">")
    parity.write(result, tmp_path / "out" / "p.json")
    assert json.loads((tmp_path / "out" / "p.json").read_text()) == result
