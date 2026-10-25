"""LoRA training: a chat-format dataset in, a 4-bit model folder out.

The building blocks (examples, tokenizing, LoRA, fuse + quantize, the model
folder) are shared by `train --tiny`, which checks the whole round trip on
40 synthetic examples, and the real `train` built on labeled thoughts.

Training examples are tokenized the way the app prompts: the system and
user messages go through the chat template with the generation prompt and
`chat_template_options` (thinking off), then the reply and the end-of-turn
token follow. The loss only counts the reply.
"""

from __future__ import annotations

import hashlib
import json
import math
import random
import shutil
import tempfile
import time
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path

from . import prompt as cleanup_prompt
from .drafter import add_drafter
from .generation import END_OF_TURN_TOKENS, package_version, read_jsonl
from .models import (
    DEFAULT_MODELS_DIR,
    QUANTIZATION,
    Candidate,
    MissingML,
    ModelError,
    finish_folder,
    install_folder,
    snapshot,
    utc_now,
    write_manifest,
)

# LoRA targets, as module paths inside a decoder layer. Paths a layer doesn't
# have are skipped, layer by layer.
# - qwen3_5: three GatedDeltaNet layers (linear_attn) then one full attention
#   layer, repeating. The small per-head gate projections (in_proj_a/b) are
#   left alone.
# - gemma4: the last layers share K/V with earlier ones and have no k_proj or
#   v_proj, so only q/o and the MLP are adapted there.
LORA_KEYS = {
    "qwen3_5": (
        "linear_attn.in_proj_qkv", "linear_attn.in_proj_z", "linear_attn.out_proj",
        "self_attn.q_proj", "self_attn.k_proj", "self_attn.v_proj", "self_attn.o_proj",
        "mlp.gate_proj", "mlp.up_proj", "mlp.down_proj",
    ),
    "gemma4": (
        "self_attn.q_proj", "self_attn.k_proj", "self_attn.v_proj", "self_attn.o_proj",
        "mlp.gate_proj", "mlp.up_proj", "mlp.down_proj",
    ),
}

# Training on bf16 weights needs the text weights themselves plus about as
# much again for the transformer layers (activations, LoRA and optimizer
# state with checkpointing). Embedding tables only sit in memory, so they
# count once: Gemma's per-layer embeddings are 5.5 of its 9.3 GB. Measured on
# qwen3.5-2b: estimate 6.5 GB, peak 6.7 GB. Above the budget, train on the
# 4-bit folder instead (QLoRA).
MEMORY_BUDGET_FRACTION = 0.6


@dataclass
class LoraSettings:
    layers: int = 16
    rank: int = 8
    scale: float = 20.0
    dropout: float = 0.0
    iterations: int = 60
    # 5e-5 with scale 20 overfit the 40 tiny examples badly enough to break
    # spelling ("revers a string") on one batch order and not on another.
    learning_rate: float = 1e-5
    batch_size: int = 1
    grad_checkpoint: bool = True
    max_seq_length: int = 1024
    seed: int = 0
    steps_per_report: int = 10
    steps_per_eval: int = 40


@dataclass
class TrainResult:
    folder: Path
    manifest: dict
    timings: dict = field(default_factory=dict)


def reply_text(cleaned: str, prompt: dict | None = None) -> str:
    """The reply the model should give: {"cleaned": "..."} with the same
    string escaping as the prompt's input JSON."""
    prompt = prompt or cleanup_prompt.load()
    return "{" + cleanup_prompt.json_string(prompt["output_key"]) + ": " + cleanup_prompt.json_string(cleaned) + "}"


def example(transcript: str, cleaned: str, terms: list[str] | tuple[str, ...] = (), prompt: dict | None = None) -> dict:
    """One chat-format training example (mlx-lm's {"messages": [...]})."""
    messages = cleanup_prompt.messages(transcript, terms, prompt)
    return {"messages": [*messages, {"role": "assistant", "content": reply_text(cleaned, prompt)}]}


def write_jsonl(rows: list[dict], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(row, ensure_ascii=False) + "\n" for row in rows))


def files_hash(*paths: Path) -> str:
    digest = hashlib.sha256()
    for path in paths:
        digest.update(path.name.encode() + b"\0" + path.read_bytes() + b"\0")
    return digest.hexdigest()


def end_of_turn_id(tokenizer) -> int:
    vocab = tokenizer.get_vocab()
    for token in END_OF_TURN_TOKENS:
        if token in vocab:
            return vocab[token]
    return tokenizer.eos_token_id


def tokenize(tokenizer, row: dict, chat_template_options: dict) -> tuple[list[int], int]:
    """(token IDs, index of the first reply token) for one example."""
    *messages, reply = row["messages"]
    if reply.get("role") != "assistant":
        raise ModelError("each training example must end with the assistant's reply")
    text = tokenizer.apply_chat_template(messages, add_generation_prompt=True, tokenize=False,
                                         **chat_template_options)
    bos = tokenizer.bos_token
    prompt_ids = tokenizer.encode(text, add_special_tokens=bos is None or not text.startswith(bos))
    reply_ids = tokenizer.encode(reply["content"], add_special_tokens=False) + [end_of_turn_id(tokenizer)]
    return prompt_ids + reply_ids, len(prompt_ids)


def text_weight_bytes(folder: Path) -> tuple[int, int]:
    """(all, embedding) bytes of the weights mlx-lm keeps for the text model.
    Loads lazily, so nothing is read; vision and audio towers are dropped."""
    from mlx.utils import tree_flatten
    from mlx_lm.utils import load_model

    model, _ = load_model(folder, lazy=True)
    params = tree_flatten(model.parameters())
    return sum(v.nbytes for _, v in params), sum(v.nbytes for k, v in params if "embed" in k)


def bf16_training_bytes(total: int, embeddings: int) -> int:
    return total + (total - embeddings)


def physical_memory() -> int:
    import os

    return os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES")


def choose_base(cand: Candidate, models_dir: Path) -> tuple[Path, str]:
    """The weights to train on: the bf16 snapshot when it fits in memory,
    otherwise the prepared 4-bit folder."""
    source = snapshot(cand)
    if bf16_training_bytes(*text_weight_bytes(source)) <= physical_memory() * MEMORY_BUDGET_FRACTION:
        return source, "bf16"
    q4 = models_dir / cand.base_id
    if not q4.exists():
        raise ModelError(f"{cand.id} is too big to train in bf16 here and {q4} isn't prepared; "
                         f"run: irudd-voice models prepare {cand.id}")
    return q4, "q4"


def reply_mask(lengths, steps):
    """Which targets count: from the first reply token through the last real
    token. mlx-lm 0.32.2's default_loss uses `steps <= length`, which also
    counts the padding token after the sequence (ID 0: Gemma's <pad>, which
    its logit softcap can't fit, so its loss stalled near 0.8)."""
    import mlx.core as mx

    return mx.logical_and(steps >= lengths[:, 0:1], steps < lengths[:, 1:])


def reply_loss(model, batch, lengths):
    """Cross-entropy over the reply tokens only (see reply_mask)."""
    import mlx.core as mx
    import mlx.nn as nn

    inputs, targets = batch[:, :-1], batch[:, 1:]
    logits = model(inputs)
    mask = reply_mask(lengths, mx.arange(1, targets.shape[1] + 1))
    ce = nn.losses.cross_entropy(logits, targets) * mask
    ntoks = mask.sum()
    return ce.astype(mx.float32).sum() / ntoks, ntoks


def train_lora(model, tokenizer, family: str, train_rows: list[dict], valid_rows: list[dict],
               adapter_dir: Path, settings: LoraSettings, log=print) -> dict:
    """Trains LoRA adapters in place on `model` with mlx-lm's trainer and
    returns the losses."""
    import mlx.core as mx
    import mlx.optimizers as optim
    import numpy as np
    from mlx_lm.tuner.callbacks import TrainingCallback
    from mlx_lm.tuner.trainer import TrainingArgs, train
    from mlx_lm.tuner.utils import linear_to_lora_layers

    options = cleanup_prompt.load()["chat_template_options"]
    train_set = [tokenize(tokenizer, row, options) for row in train_rows]
    valid_set = [tokenize(tokenizer, row, options) for row in valid_rows]

    mx.random.seed(settings.seed)
    np.random.seed(settings.seed)  # mlx-lm shuffles batches with numpy's global state
    model.freeze()
    if settings.layers > len(model.layers):
        raise ModelError(f"the model has only {len(model.layers)} layers")
    lora = {"rank": settings.rank, "scale": settings.scale, "dropout": settings.dropout,
            "keys": list(LORA_KEYS[family])}
    linear_to_lora_layers(model, settings.layers, lora)
    adapter_dir.mkdir(parents=True, exist_ok=True)
    (adapter_dir / "adapter_config.json").write_text(json.dumps(
        {"fine_tune_type": "lora", "num_layers": settings.layers, "lora_parameters": lora}, indent=2))

    losses: dict = {"train": [], "valid": []}

    class Record(TrainingCallback):
        def on_train_loss_report(self, info):
            losses["train"].append((info["iteration"], round(info["train_loss"], 4)))
            log(f"iteration {info['iteration']}: train loss {info['train_loss']:.3f}, "
                f"peak memory {info.get('peak_memory', 0):.1f} GB")

        def on_val_loss_report(self, info):
            losses["valid"].append((info["iteration"], round(info["val_loss"], 4)))
            log(f"iteration {info['iteration']}: validation loss {info['val_loss']:.3f}")

    args = TrainingArgs(
        batch_size=settings.batch_size, iters=settings.iterations, val_batches=-1,
        steps_per_report=settings.steps_per_report, steps_per_eval=settings.steps_per_eval,
        steps_per_save=settings.iterations, adapter_file=str(adapter_dir / "adapters.safetensors"),
        max_seq_length=settings.max_seq_length, grad_checkpoint=settings.grad_checkpoint,
    )
    train(model=model, optimizer=optim.Adam(learning_rate=settings.learning_rate), train_dataset=train_set,
          val_dataset=valid_set, args=args, loss=reply_loss, training_callback=Record())
    losses["peak_memory_gb"] = round(mx.get_peak_memory() / 1e9, 2)
    return losses


def fuse_and_save(model, tokenizer, config: dict, source: Path, staging: Path, base_weights: str) -> None:
    """Merges the adapters into the weights, quantizes to 4-bit (group 64)
    unless the base already was, and saves an MLX folder."""
    from mlx.utils import tree_unflatten
    from mlx_lm.utils import quantize_model, save

    fused = [(name, module.fuse()) for name, module in model.named_modules() if hasattr(module, "fuse")]
    if fused:
        model.update_modules(tree_unflatten(fused))
    if base_weights == "bf16":
        model, config = quantize_model(model, config, QUANTIZATION["group_size"], QUANTIZATION["bits"])
    save(staging, source, model, tokenizer, config, donate_model=False)
    finish_folder(staging, source)


def train(
    cand: Candidate,
    train_path: Path,
    valid_path: Path,
    model_id: str,
    *,
    models_dir: Path = DEFAULT_MODELS_DIR,
    settings: LoraSettings | None = None,
    chunks: int | None = None,
    dataset_hash: str | None = None,
    extra_training: dict | None = None,
    log=print,
) -> TrainResult:
    """Dataset files in → `<models_dir>/<model_id>/` with a `training` block.
    `dataset_hash` should come from the dataset's own summary (train_dataset
    does this) so reports and promotion compare the same value; without it
    the files are hashed."""
    try:
        from mlx_lm.utils import load
    except ImportError as error:
        raise MissingML(error) from None
    settings = settings or LoraSettings()
    train_rows, valid_rows = read_jsonl(train_path), read_jsonl(valid_path)
    if not train_rows or not valid_rows:
        raise ModelError("training needs at least one train and one validation example")
    target = models_dir / model_id
    timings: dict = {}

    source, base_weights = choose_base(cand, models_dir)
    log(f"training {model_id} on the {base_weights} weights of {cand.repo}, {len(train_rows)} examples")
    started = time.perf_counter()
    model, tokenizer, config = load(str(source), return_config=True)
    timings["load_seconds"] = round(time.perf_counter() - started, 1)

    models_dir.mkdir(parents=True, exist_ok=True)
    staging = models_dir / f".{model_id}.partial"
    shutil.rmtree(staging, ignore_errors=True)
    with tempfile.TemporaryDirectory(prefix="irudd-voice-adapters-") as adapters:
        started = time.perf_counter()
        losses = train_lora(model, tokenizer, cand.family, train_rows, valid_rows, Path(adapters), settings, log)
        timings["train_seconds"] = round(time.perf_counter() - started, 1)
        try:
            started = time.perf_counter()
            fuse_and_save(model, tokenizer, config, source, staging, base_weights)
            # mlx-lm's save keeps only the text model; the drafter's target
            # class needs the vision tower back, and the folder its drafter.
            drafter = add_drafter(staging, cand, log=log)
            timings["fuse_seconds"] = round(time.perf_counter() - started, 1)
            training = {
                "method": "lora",
                "dataset_hash": dataset_hash or files_hash(train_path, valid_path),
                "chunks": chunks if chunks is not None else len(train_rows),
                "layers": settings.layers,
                "iterations": settings.iterations,
                "mlx_lm_version": package_version("mlx-lm"),
                "trained_at": utc_now(),
                "base_weights": base_weights,
                "lora": {"rank": settings.rank, "scale": settings.scale, "learning_rate": settings.learning_rate,
                         "batch_size": settings.batch_size, "keys": list(LORA_KEYS[cand.family])},
                "train_examples": len(train_rows),
                "valid_examples": len(valid_rows),
                "final_train_loss": losses["train"][-1][1] if losses["train"] else None,
                "final_valid_loss": losses["valid"][-1][1] if losses["valid"] else None,
                "peak_memory_gb": losses["peak_memory_gb"],
                **(extra_training or {}),
            }
            manifest = write_manifest(staging, model_id, cand, prompt_version=cleanup_prompt.load()["version"],
                                      training=training, drafter=drafter)
            install_folder(staging, target)
        finally:
            shutil.rmtree(staging, ignore_errors=True)
    return TrainResult(target, manifest, timings)


# Synthetic examples for `train --tiny`: what was said and what should be
# typed. Each is used twice, with different fillers in front, so the run sees
# 40 examples. They exist to prove the training round trip, not to teach the
# model anything useful.
TINY_REQUESTS = (
    ("can you explain why the build failed", "Can you explain why the build failed?"),
    ("rename the parse config function to load config", "Rename the parse config function to load config."),
    ("add a test for the empty input case", "Add a test for the empty input case."),
    ("don't change the public api", "Don't change the public API."),
    ("set the retry count to three no five", "Set the retry count to five."),
    ("move the helper into utils dot py", "Move the helper into utils dot py."),
    ("what does the cache flag do", "What does the cache flag do?"),
    ("write a function that sorts the list by date", "Write a function that sorts the list by date."),
    ("check the logs and tell me what went wrong", "Check the logs and tell me what went wrong."),
    ("make the button blue sorry make it green", "Make it green."),
    ("never commit the api key", "Never commit the API key."),
    ("update the readme with the new install steps", "Update the readme with the new install steps."),
    ("is it safe to delete the old migrations", "Is it safe to delete the old migrations?"),
    ("the server should listen on port eight thousand", "The server should listen on port 8000."),
    ("split the view into two smaller views", "Split the view into two smaller views."),
    ("keep the old behaviour behind a flag", "Keep the old behaviour behind a flag."),
    ("how do I run only the slow tests", "How do I run only the slow tests?"),
    ("use the logger instead of print", "Use the logger instead of print."),
    ("bump the timeout to thirty seconds and not more", "Bump the timeout to thirty seconds and not more."),
    ("open the settings file and remove the unused keys", "Open the settings file and remove the unused keys."),
)
TINY_FILLERS = ("", "um ", "so ", "uh ", "okay so ", "um so basically ", "yeah ", "so like ")


def next_model_id(cand: Candidate, models_dir: Path, con, day: date | None = None) -> str:
    """`<candidate>-ft-<date>-<n>`, the first n that has neither a folder
    nor a models row."""
    stem = f"{cand.id}-ft-{(day or date.today()).strftime('%Y%m%d')}"
    taken = {row[0] for row in con.execute("SELECT id FROM models WHERE id LIKE ?", (stem + "-%",))}
    n = 1
    while f"{stem}-{n}" in taken or (models_dir / f"{stem}-{n}").exists():
        n += 1
    return f"{stem}-{n}"


def train_dataset(cand: Candidate, data: Path, model_id: str, *, models_dir: Path = DEFAULT_MODELS_DIR,
                  settings: LoraSettings | None = None, log=print) -> TrainResult:
    """Trains on a `dataset build` folder: train.jsonl, valid.jsonl (the
    selection split) and dataset.json, whose dataset_hash goes in the model's
    training block unchanged."""
    summary_path = data / "dataset.json"
    if not summary_path.exists():
        raise ModelError(f"{data} has no dataset.json; build it with: irudd-voice dataset build --out {data}")
    summary = json.loads(summary_path.read_text())
    prompt_version = cleanup_prompt.load()["version"]
    if summary.get("prompt_version") != prompt_version:
        raise ModelError(f"the dataset was built for prompt {summary.get('prompt_version')}, not {prompt_version}; "
                         "build it again")
    examples, augmented = summary["examples"], summary.get("augmented", {})
    return train(cand, data / "train.jsonl", data / "valid.jsonl", model_id, models_dir=models_dir,
                 settings=settings, chunks=examples["train"] - augmented.get("train", 0),
                 dataset_hash=summary["dataset_hash"],
                 extra_training={"candidate": cand.id, "base_model": cand.base_id,
                                 "teacher_prompt_versions": summary.get("teacher_prompt_versions", []),
                                 "vocabulary_hash": summary.get("vocabulary_hash")}, log=log)


def tiny_examples(seed: int = 0) -> list[dict]:
    rng = random.Random(seed)
    rows = []
    for spoken, cleaned in TINY_REQUESTS:
        for filler in rng.sample(TINY_FILLERS, 2):
            rows.append(example(filler + spoken, cleaned))
    rng.shuffle(rows)
    return rows


def tiny_model_id(cand: Candidate, day: date | None = None) -> str:
    return f"{cand.id}-tiny-{(day or date.today()).strftime('%Y%m%d')}"


def train_tiny(cand: Candidate, models_dir: Path = DEFAULT_MODELS_DIR, work_dir: Path | None = None,
               settings: LoraSettings | None = None, log=print) -> TrainResult:
    rows = tiny_examples()
    valid_count = max(1, math.ceil(len(rows) / 10))
    with tempfile.TemporaryDirectory(prefix="irudd-voice-tiny-") as tmp:
        data = work_dir or Path(tmp)
        write_jsonl(rows[valid_count:], data / "train.jsonl")
        write_jsonl(rows[:valid_count], data / "valid.jsonl")
        return train(cand, data / "train.jsonl", data / "valid.jsonl", tiny_model_id(cand),
                     models_dir=models_dir, settings=settings, extra_training={"synthetic": True}, log=log)
