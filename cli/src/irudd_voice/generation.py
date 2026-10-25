"""Greedy generation with a model folder, the way the app does it.

Eval and parity-reference share this, so the token IDs written for the
Swift parity check come from the same code that eval scores.
"""

from __future__ import annotations

import hashlib
import json
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path

from . import prompt as cleanup_prompt
from .models import MissingML, read_manifest

# Chat-template end-of-turn tokens. A model stops at these as well as at the
# eos IDs in config.json / generation_config.json (Gemma lists <turn|> there).
END_OF_TURN_TOKENS = ("<|im_end|>", "<turn|>", "<end_of_turn>")
# Also stop at these, but never train a reply to end with them: Qwen's
# end-of-text (248044 in Qwen3.5), which can follow a reply without <|im_end|>.
EXTRA_STOP_TOKENS = ("<|endoftext|>",)


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
    plus the chat template's end-of-turn token and Qwen's <|endoftext|>."""
    ids = set(tokenizer.eos_token_ids)
    if tokenizer.eos_token_id is not None:
        ids.add(tokenizer.eos_token_id)
    vocab = tokenizer.get_vocab()
    ids.update(vocab[t] for t in (*END_OF_TURN_TOKENS, *EXTRA_STOP_TOKENS) if t in vocab)
    return ids


def contract_hashes() -> dict:
    """Binds a report to the prompt and hard checks it was made with:
    prompt_sha256 = SHA-256 of shared/cleanup-prompt.json, hardchecks_sha256 =
    SHA-256 of hardchecks.py's bytes followed by fixtures/hard-checks.json's."""
    shared = cleanup_prompt.SHARED
    checks = hashlib.sha256((Path(__file__).parent / "hardchecks.py").read_bytes())
    checks.update((shared / "fixtures" / "hard-checks.json").read_bytes())
    return {
        "prompt_sha256": hashlib.sha256((shared / "cleanup-prompt.json").read_bytes()).hexdigest(),
        "hardchecks_sha256": checks.hexdigest(),
    }


def hardware() -> str:
    """Model identifier, chip and memory, e.g. "Mac17,4 Apple M5 24 GB"."""
    def sysctl(name: str) -> str:
        try:
            return subprocess.run(["sysctl", "-n", name], capture_output=True, text=True, check=True).stdout.strip()
        except (OSError, subprocess.CalledProcessError):
            return ""

    memory = sysctl("hw.memsize")
    parts = [sysctl("hw.model"), sysctl("machdep.cpu.brand_string"),
             f"{int(memory) // 2**30} GB" if memory.isdigit() else ""]
    return " ".join(p for p in parts if p) or "unknown"


def read_jsonl(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
