"""Model folders: the candidate table, `models prepare`, manifests and checks.

A model folder holds MLX weights plus `manifest.json` (shared/manifest.schema.md).
The app verifies every checksum before it loads a folder, so anything that
writes a folder writes the manifest last, over the final files.

The MLX packages are only needed to build folders, not to read manifests:
they're in the `ml` dependency group and imported inside the functions that
use them.
"""

from __future__ import annotations

import hashlib
import json
import re
import shutil
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

DEFAULT_MODELS_DIR = Path.home() / "Library" / "Application Support" / "irudd-voice" / "models"
MANIFEST_SCHEMA = 1
QUANTIZATION = {"bits": 4, "group_size": 64}
ID_PATTERN = re.compile(r"[a-z0-9][a-z0-9.-]*")
ML_HINT = "the model tools need the ml dependency group: uv run --group ml irudd-voice ..."


def valid_id(model_id: str) -> bool:
    """A model id is a folder name: ID_PATTERN and no "..", the same rule as
    the app's ModelManifest.isValidID (shared/manifest.schema.md)."""
    return ID_PATTERN.fullmatch(model_id) is not None and ".." not in model_id


@dataclass(frozen=True)
class Candidate:
    id: str
    family: str
    repo: str
    revision: str

    @property
    def base_id(self) -> str:
        return f"{self.id}-base-q4"


# Pinned so every machine converts the same weights. Revisions are full
# commit hashes; a moved branch on the Hub can't change what we build.
CANDIDATES = {
    c.id: c
    for c in (
        Candidate("qwen3.5-2b", "qwen3_5", "Qwen/Qwen3.5-2B", "15852e8c16360a2fea060d615a32b45270f8a8fc"),
        Candidate("gemma-4-e2b", "gemma4", "google/gemma-4-E2B-it", "3e22461f65e89153144f8adb70e3b8c2cc9845a7"),
        Candidate("qwen3.5-4b", "qwen3_5", "Qwen/Qwen3.5-4B", "851bf6e806efd8d0a36b00ddf55e13ccb7b8cd0a"),
    )
}

# The model the app uses while active_model is empty: the baseline pick
# (docs/models/baseline.md: gemma-4-e2b-base-q4).
DEFAULT_CANDIDATE = "gemma-4-e2b"


def default_model_id() -> str:
    return CANDIDATES[DEFAULT_CANDIDATE].base_id


def candidate_for(manifest: dict) -> Candidate:
    """The candidate a model folder was built from."""
    for cand in CANDIDATES.values():
        if (cand.repo, cand.revision) == (manifest.get("base_repo"), manifest.get("base_revision")):
            return cand
    raise ModelError(f"{manifest.get('id')} was built from {manifest.get('base_repo')}@{manifest.get('base_revision')}, "
                     "which isn't a known candidate")


# What a conversion needs from a snapshot. The Qwen checkpoints also carry a
# vision tower; mlx-lm drops it when it loads them as text models.
SNAPSHOT_PATTERNS = ["*.json", "*.safetensors", "*.jinja", "*.txt", "tokenizer.model"]


class ModelError(Exception):
    """A model folder or command can't be used; the message says why."""


class MissingML(ModelError):
    def __init__(self, error: ImportError):
        super().__init__(f"{error.name or 'mlx'} is not installed; {ML_HINT}")


def candidate(name: str) -> Candidate:
    try:
        return CANDIDATES[name]
    except KeyError:
        raise ModelError(f"unknown candidate {name!r}; choose one of: {', '.join(CANDIDATES)}") from None


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def chat_template_sha256(folder: Path) -> str | None:
    """chat_template.jinja's bytes if the folder has one, otherwise the
    template string in tokenizer_config.json (shared/manifest.schema.md)."""
    jinja = folder / "chat_template.jinja"
    if jinja.exists():
        return sha256_file(jinja)
    config = folder / "tokenizer_config.json"
    template = json.loads(config.read_text()).get("chat_template") if config.exists() else None
    if isinstance(template, str):
        return hashlib.sha256(template.encode()).hexdigest()
    return None


def model_files(folder: Path) -> list[str]:
    """The folder's files that belong to the model, as relative paths: every
    file except manifest.json and hidden files. Hidden means the file name or
    the name of any folder on its path starts with "." (.DS_Store, .cache/…),
    the same rule as the Swift side."""
    return sorted(
        rel.as_posix()
        for rel in (p.relative_to(folder) for p in folder.rglob("*") if p.is_file())
        if rel.as_posix() != "manifest.json" and not any(part.startswith(".") for part in rel.parts)
    )


def utc_now() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def write_manifest(
    folder: Path,
    model_id: str,
    cand: Candidate,
    *,
    prompt_version: str | None = None,
    training: dict | None = None,
    created_at: str | None = None,
) -> dict:
    """Hashes every file in the folder and writes manifest.json (schema 1)."""
    if not valid_id(model_id):
        raise ModelError(f"model id {model_id!r} must match {ID_PATTERN.pattern} without '..'")
    if (training is None) != (prompt_version is None):
        raise ModelError("a trained model needs a prompt_version and a base model must not have one")
    files = {name: sha256_file(folder / name) for name in model_files(folder)}
    if "tokenizer.json" not in files:
        raise ModelError(f"{folder} has no tokenizer.json")
    manifest = {
        "schema": MANIFEST_SCHEMA,
        "id": model_id,
        "family": cand.family,
        "base_repo": cand.repo,
        "base_revision": cand.revision,
        "source_repo": None,
        "source_revision": None,
        "tokenizer_sha256": files["tokenizer.json"],
        "chat_template_sha256": chat_template_sha256(folder),
        "prompt_version": prompt_version,
        "quantization": dict(QUANTIZATION),
        "files": files,
        "training": training,
        "created_at": created_at or utc_now(),
    }
    (folder / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return manifest


def read_manifest(folder: Path) -> dict:
    path = folder / "manifest.json"
    if not path.exists():
        raise ModelError(f"{folder} has no manifest.json")
    try:
        manifest = json.loads(path.read_text())
    except json.JSONDecodeError as error:
        raise ModelError(f"{path} is not valid JSON: {error}") from None
    if not isinstance(manifest, dict) or manifest.get("schema") != MANIFEST_SCHEMA:
        raise ModelError(f"{path} has unknown schema {manifest.get('schema') if isinstance(manifest, dict) else None!r}")
    return manifest


def verify(folder: Path) -> list[str]:
    """Problems with a model folder, or [] when the manifest matches every file."""
    try:
        manifest = read_manifest(folder)
    except ModelError as error:
        return [str(error)]
    problems = []
    if manifest.get("id") != folder.name:
        problems.append(f"manifest id {manifest.get('id')!r} is not the folder name {folder.name!r}")
    files = manifest.get("files")
    if not isinstance(files, dict) or not files:
        return problems + ["manifest lists no files"]
    on_disk = set(model_files(folder))
    for name in sorted(on_disk - files.keys()):
        problems.append(f"{name}: not in the manifest")
    for name, expected in sorted(files.items()):
        path = folder / name
        if not path.is_file():
            problems.append(f"{name}: missing")
        elif sha256_file(path) != expected:
            problems.append(f"{name}: checksum differs")
    if files.get("tokenizer.json") != manifest.get("tokenizer_sha256"):
        problems.append("tokenizer_sha256 does not match tokenizer.json")
    if (folder / "tokenizer.json").exists() and manifest.get("chat_template_sha256") != chat_template_sha256(folder):
        problems.append("chat_template_sha256 does not match the chat template")
    return problems


def snapshot(cand: Candidate) -> Path:
    """The pinned Hugging Face snapshot, downloaded into the HF cache if needed."""
    try:
        from huggingface_hub import snapshot_download
    except ImportError as error:
        raise MissingML(error) from None
    try:
        # A pinned commit never changes, so a cached copy needs no network
        # (without this, a DNS outage stalled `train` for most of an hour).
        return Path(snapshot_download(cand.repo, revision=cand.revision, allow_patterns=SNAPSHOT_PATTERNS,
                                      local_files_only=True))
    except Exception:  # not cached yet (huggingface_hub raises several error types)
        return Path(snapshot_download(cand.repo, revision=cand.revision, allow_patterns=SNAPSHOT_PATTERNS))


def finish_folder(staging: Path, source: Path) -> None:
    """Tidies what mlx-lm saved: keeps the snapshot's generation_config.json
    (Gemma's stop tokens live there) and drops the generated model card."""
    generation = source / "generation_config.json"
    if generation.exists() and not (staging / "generation_config.json").exists():
        shutil.copy(generation, staging / "generation_config.json")
    (staging / "README.md").unlink(missing_ok=True)


def install_folder(staging: Path, target: Path) -> None:
    """Moves a finished folder into place, replacing an older one."""
    if target.exists():
        old = target.with_name(f".{target.name}.old")
        shutil.rmtree(old, ignore_errors=True)
        target.rename(old)
        staging.rename(target)
        shutil.rmtree(old)
    else:
        staging.rename(target)


def prepare(cand: Candidate, models_dir: Path = DEFAULT_MODELS_DIR, *, force: bool = False, log=print) -> tuple[Path, dict]:
    """Pinned snapshot → mlx-lm convert (text only) → 4-bit, group 64 →
    `<models_dir>/<candidate>-base-q4/` with a manifest."""
    target = models_dir / cand.base_id
    if target.exists() and not force:
        problems = verify(target)
        if not problems:
            manifest = read_manifest(target)
            built_from = (manifest.get("base_repo"), manifest.get("base_revision"), manifest.get("family"))
            if built_from != (cand.repo, cand.revision, cand.family):
                problems = [f"it was built from {built_from[0]}@{built_from[1]}, not {cand.repo}@{cand.revision}"]
        if problems:
            raise ModelError(f"{target} exists but can't be reused ({problems[0]}); run again with --force")
        log(f"{target} is already prepared and verifies")
        return target, manifest
    try:
        from mlx_lm import convert
    except ImportError as error:
        raise MissingML(error) from None

    source = snapshot(cand)
    models_dir.mkdir(parents=True, exist_ok=True)
    staging = models_dir / f".{cand.base_id}.partial"
    shutil.rmtree(staging, ignore_errors=True)
    log(f"converting {cand.repo}@{cand.revision[:12]} to 4-bit")
    try:
        convert(str(source), str(staging), quantize=True, q_group_size=QUANTIZATION["group_size"],
                q_bits=QUANTIZATION["bits"])
        finish_folder(staging, source)
        manifest = write_manifest(staging, cand.base_id, cand)
        install_folder(staging, target)
    finally:
        shutil.rmtree(staging, ignore_errors=True)
    return target, manifest


def record(db_path: Path, manifest: dict) -> None:
    """Inserts or updates the folder's row in the `models` table. An update
    keeps the row (and active_model's reference to it) in place."""
    from . import db

    training = manifest.get("training") or {}
    con = db.connect(db_path, write=True)
    try:
        with db.write_transaction(con):
            con.execute(
                "INSERT INTO models (id, base_repo, base_revision, manifest_json, prompt_version, dataset_hash, "
                "trained_chunks, trained_at, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) "
                "ON CONFLICT (id) DO UPDATE SET base_repo = excluded.base_repo, "
                "base_revision = excluded.base_revision, manifest_json = excluded.manifest_json, "
                "prompt_version = excluded.prompt_version, dataset_hash = excluded.dataset_hash, "
                "trained_chunks = excluded.trained_chunks, trained_at = excluded.trained_at, "
                "created_at = excluded.created_at",
                (manifest["id"], manifest["base_repo"], manifest["base_revision"], json.dumps(manifest),
                 manifest["prompt_version"], training.get("dataset_hash"), training.get("chunks"),
                 training.get("trained_at"), manifest["created_at"]),
            )
    finally:
        con.close()
