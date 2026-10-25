"""Greedy generation with a model folder, the way the app does it.

Eval and parity-reference share this, so the token IDs written for the
Swift parity check come from the same code that eval scores.
"""

from __future__ import annotations

import json
import time
from dataclasses import dataclass
from pathlib import Path

from . import prompt as cleanup_prompt
from .models import MissingML, read_manifest

# Chat-template end-of-turn tokens. A model stops at these as well as at the
# eos IDs in config.json / generation_config.json (Gemma lists <turn|> there).
END_OF_TURN_TOKENS = ("<|im_end|>", "<turn|>", "<end_of_turn>")


@dataclass
class Generation:
    token_ids: list[int]  # generated tokens, without the stop token
    stop_token_id: int | None  # the token that ended generation, None at the limit
    text: str
    seconds: float

    @property
    def hit_limit(self) -> bool:
        return self.stop_token_id is None


class Model:
    """A loaded model folder, ready to clean transcripts."""

    def __init__(self, folder: Path, prompt: dict | None = None):
        try:
            import mlx.core as mx
            from mlx_lm import load
            from mlx_lm.generate import generate_step
        except ImportError as error:
            raise MissingML(error) from None
        self._mx = mx
        self._generate_step = generate_step
        self.folder = folder
        self.manifest = read_manifest(folder)
        self.prompt = prompt or cleanup_prompt.load()
        self.model, self.tokenizer = load(str(folder))
        self.stop_ids = stop_token_ids(self.tokenizer)

    def prompt_text(self, transcript: str, terms: list[str] | tuple[str, ...] = ()) -> str:
        messages = cleanup_prompt.messages(transcript, terms, self.prompt)
        return self.tokenizer.apply_chat_template(
            messages, add_generation_prompt=True, tokenize=False, **self.prompt["chat_template_options"]
        )

    def encode(self, text: str) -> list[int]:
        # Same rule as mlx-lm's generate: templates that already start with
        # the BOS token (Gemma) don't get a second one.
        bos = self.tokenizer.bos_token
        return self.tokenizer.encode(text, add_special_tokens=bos is None or not text.startswith(bos))

    def generate(self, prompt_ids: list[int], max_tokens: int) -> Generation:
        mx = self._mx
        start = time.perf_counter()
        tokens: list[int] = []
        stop = None
        steps = self._generate_step(mx.array(prompt_ids), self.model, max_tokens=max_tokens,
                                    sampler=lambda logits: mx.argmax(logits, axis=-1))
        for token, _ in steps:
            token = int(token)
            if token in self.stop_ids:
                stop = token
                break
            tokens.append(token)
        seconds = time.perf_counter() - start
        mx.clear_cache()
        return Generation(tokens, stop, self.tokenizer.decode(tokens), seconds)

    def clean(self, transcript: str, terms: list[str] | tuple[str, ...] = (),
              max_tokens: int | None = None) -> Generation:
        ids = self.encode(self.prompt_text(transcript, terms))
        return self.generate(ids, max_tokens or self.prompt["generation"]["max_tokens"])


def stop_token_ids(tokenizer) -> set[int]:
    """eos IDs (mlx-lm merges generation_config.json's into the tokenizer)
    plus the chat template's end-of-turn token."""
    ids = set(tokenizer.eos_token_ids)
    if tokenizer.eos_token_id is not None:
        ids.add(tokenizer.eos_token_id)
    vocab = tokenizer.get_vocab()
    ids.update(vocab[t] for t in END_OF_TURN_TOKENS if t in vocab)
    return ids


def read_jsonl(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
