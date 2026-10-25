"""The model commands: models prepare/verify/register, train, eval and
parity-reference. All but `models verify` and `models register` need the
`ml` dependency group; MLX is only imported when one of them runs.
"""

from __future__ import annotations

import argparse
import functools
import json
import sys
from pathlib import Path

from . import db
from .models import DEFAULT_MODELS_DIR, ModelError

CANDIDATE_HELP = "qwen3.5-2b, gemma-4-e2b or qwen3.5-4b"
DB_HELP = "database to record the model in (default: the app's, skipped if it doesn't exist yet)"


def reports_errors(run):
    @functools.wraps(run)
    def wrapper(args) -> int:
        try:
            return run(args)
        except (ModelError, db.SchemaError) as error:
            print(f"irudd-voice: {error}", file=sys.stderr)
            return 1

    return wrapper


def record(args, manifest: dict) -> None:
    """Adds the folder to the `models` table (shared/manifest.schema.md: every
    folder has a row). Without --db that's the app's database, if the app has
    created it; a --db that doesn't exist is an error."""
    from . import models

    path = getattr(args, "db", None) or db.DEFAULT_PATH
    if not Path(path).exists() and Path(path) == db.DEFAULT_PATH:
        print(f"No database at {path} yet, so {manifest['id']} isn't recorded. After the app has run once: "
              f"irudd-voice models register <folder>", file=sys.stderr)
        return
    models.record(Path(path), manifest)
    print(f"recorded {manifest['id']} in {path}", file=sys.stderr)


@reports_errors
def prepare_command(args) -> int:
    from . import models

    folder, manifest = models.prepare(models.candidate(args.candidate), args.models_dir, force=args.force,
                                      log=lambda line: print(line, file=sys.stderr))
    record(args, manifest)
    print(folder)
    return 0


@reports_errors
def verify_command(args) -> int:
    from . import models

    problems = models.verify(args.dir)
    for problem in problems:
        print(f"{args.dir.name}: {problem}", file=sys.stderr)
    if not problems:
        print(f"{args.dir.name}: manifest and checksums OK")
    return 1 if problems else 0


@reports_errors
def register_command(args) -> int:
    from . import models

    problems = models.verify(args.dir)
    if problems:
        raise ModelError(f"{args.dir} doesn't verify ({problems[0]}); nothing recorded")
    record(args, models.read_manifest(args.dir))
    return 0


@reports_errors
def train_command(args) -> int:
    from . import models, train

    log = lambda line: print(line, file=sys.stderr)  # noqa: E731
    cand = models.candidate(args.candidate)
    if not args.tiny:
        # Training on labeled thoughts (train.train_dataset) gets its command
        # with the unload lease in the trainloop step.
        raise ModelError("only `train --tiny <candidate>` exists so far")
    result = train.train_tiny(cand, args.models_dir, log=log)
    record(args, result.manifest)
    print(json.dumps({"folder": str(result.folder), "timings": result.timings,
                      "training": result.manifest["training"]}, indent=2))
    return 0


@reports_errors
def eval_command(args) -> int:
    from . import evaluate

    sets = list(evaluate.SETS) if args.set == "all" else [args.set]
    report = evaluate.evaluate_folder(args.dir, sets, log=lambda line: print(line, file=sys.stderr))
    text = json.dumps(report, indent=1, ensure_ascii=False) + "\n"
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(text)
        summary = {name: s["summary"] for name, s in report["sets"].items()}
        text = json.dumps({"model_id": report["model_id"], "summary": summary,
                           "hard_check_gate": report["hard_check_gate"]}, indent=2) + "\n"
    print(text, end="")
    return 0


@reports_errors
def parity_command(args) -> int:
    from . import parity

    result = parity.reference(args.dir, args.inputs, log=lambda line: print(line, file=sys.stderr))
    parity.write(result, args.out)
    print(args.out)
    return 0


def register(commands) -> None:
    from .evaluate import SETS
    from .parity import DEFAULT_INPUTS

    models_parser = commands.add_parser("models", help="prepare, check and record model folders")
    models_commands = models_parser.add_subparsers(dest="models_command", required=True)
    prepare = models_commands.add_parser("prepare", help="convert a pinned base model to a 4-bit model folder "
                                                         "(needs --group ml)")
    prepare.add_argument("candidate", help=CANDIDATE_HELP)
    prepare.add_argument("--models-dir", type=Path, default=DEFAULT_MODELS_DIR,
                         help="where model folders go (default: the app's)")
    prepare.add_argument("--db", type=Path, default=argparse.SUPPRESS, help=DB_HELP)
    prepare.add_argument("--force", action="store_true", help="rebuild even if the folder is already there")
    prepare.set_defaults(run=prepare_command)
    verify = models_commands.add_parser("verify", help="check a model folder's manifest and checksums")
    verify.add_argument("dir", type=Path)
    verify.set_defaults(run=verify_command)
    register_parser = models_commands.add_parser("register", help="verify a model folder and record it in the "
                                                                  "models table")
    register_parser.add_argument("dir", type=Path)
    register_parser.add_argument("--db", type=Path, default=argparse.SUPPRESS, help=DB_HELP)
    register_parser.set_defaults(run=register_command)

    train = commands.add_parser("train", help="fine-tune a candidate with LoRA (needs --group ml)")
    train.add_argument("candidate", help=CANDIDATE_HELP)
    train.add_argument("--tiny", action="store_true", help="40 synthetic examples, to check the training round trip")
    train.add_argument("--models-dir", type=Path, default=DEFAULT_MODELS_DIR,
                       help="where model folders go (default: the app's)")
    train.add_argument("--db", type=Path, default=argparse.SUPPRESS, help=DB_HELP)
    train.set_defaults(run=train_command)

    evaluate = commands.add_parser("eval", help="run a model over the fixed eval sets (needs --group ml)")
    evaluate.add_argument("dir", type=Path, help="model folder")
    evaluate.add_argument("--set", choices=(*SETS, "all"), default="all")
    evaluate.add_argument("--out", type=Path, help="write the full JSON report here (default: print it)")
    evaluate.set_defaults(run=eval_command)

    parity = commands.add_parser("parity-reference", help="greedy token IDs for the Swift parity check "
                                                          "(needs --group ml)")
    parity.add_argument("dir", type=Path, help="model folder")
    parity.add_argument("--out", type=Path, required=True, help="JSON file to write")
    parity.add_argument("--inputs", type=Path, default=DEFAULT_INPUTS, help="inputs (default: evals/parity.jsonl)")
    parity.set_defaults(run=parity_command)
