"""The model commands: models prepare/verify/register, train, eval and
parity-reference. All but `models verify` and `models register` need the
`ml` dependency group; MLX is only imported when one of them runs.
"""

from __future__ import annotations

import argparse
import functools
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

from . import db
from .models import DEFAULT_MODELS_DIR, ModelError
from .vocab import DEFAULT_PATH as VOCABULARY_PATH

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


def explicit_db(args) -> Path | None:
    """The database given with --db (before or after the command), or None."""
    return getattr(args, "db", None)


def record(args, manifest: dict) -> None:
    """Adds the folder to the `models` table (shared/manifest.schema.md: every
    folder has a row). Without --db that's the app's database, if the app has
    created it; a --db that doesn't exist is an error."""
    from . import models

    path = explicit_db(args)
    if path is None:
        path = db.DEFAULT_PATH
        if not path.exists():
            print(f"No database at {path} yet, so {manifest['id']} isn't recorded. After the app has run once: "
                  f"irudd-voice models register <folder>", file=sys.stderr)
            return
    models.record(path, manifest)
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


def lower_priority(log) -> None:
    """Training runs for minutes to hours next to your work: lowest CPU
    priority (nice 10) and the Darwin background policy (`taskpolicy -b`),
    which also throttles its disk reads."""
    os.nice(10)
    result = subprocess.run(["taskpolicy", "-b", "-p", str(os.getpid())], capture_output=True, text=True,
                            check=False)
    if result.returncode != 0:
        log(f"couldn't lower the priority with taskpolicy: {result.stderr.strip()}")


def default_iterations(train_examples: int) -> int:
    """About two passes over the training examples, 100 to 1000 steps."""
    return min(1000, max(100, 2 * train_examples))


def run_settings(train_examples: int, iterations: int | None):
    from .train import LoraSettings

    iterations = iterations or default_iterations(train_examples)
    return LoraSettings(iterations=iterations, steps_per_report=max(1, min(10, iterations // 4)),
                        steps_per_eval=max(1, min(100, iterations // 2)))


def train_candidate(con, name: str | None):
    """The candidate to train: the one given, else the active model's, else
    the default."""
    from . import compare, models

    if name:
        return models.candidate(name)
    active_id, _ = compare.active(con)
    row = compare.model_row(con, active_id) if active_id else None
    return models.candidate_for(row["manifest"]) if row else models.candidate(models.DEFAULT_CANDIDATE)


@reports_errors
def train_command(args) -> int:
    from . import models, train

    log = lambda line: print(line, file=sys.stderr)  # noqa: E731
    name = args.candidate_option or args.candidate
    if not args.tiny:
        return train_run(args, name, log)
    if not name:
        raise ModelError("train --tiny needs a candidate: " + CANDIDATE_HELP)
    cand = models.candidate(name)
    result = train.train_tiny(cand, args.models_dir, log=log)
    # A tiny model is a synthetic test of the training round trip with a real
    # prompt_version: in the app's database it would look like a trained model
    # to Settings → Model and promote. Record it only into an explicit --db.
    if explicit_db(args) is not None:
        record(args, result.manifest)
    else:
        print(f"{result.manifest['id']} is a test model, so it isn't recorded in the app's database "
              "(pass --db to record it in another one)", file=sys.stderr)
    print(json.dumps({"folder": str(result.folder), "timings": result.timings,
                      "training": result.manifest["training"]}, indent=2))
    return 0


def train_run(args, name: str | None, log) -> int:
    """A full training run on labeled thoughts: always from the base
    weights, at low priority, with the app's model unloaded."""
    from . import appstate, dataset, models, train, vocab

    path = explicit_db(args) or db.DEFAULT_PATH
    con = db.connect(path)
    try:
        cand = train_candidate(con, name)
    finally:
        con.close()
    data = args.dataset
    if data is None:
        data = Path(tempfile.mkdtemp(prefix="irudd-voice-dataset-"))
        con = db.connect(path, write=True)
        try:
            dataset.build(con, data, vocab.load_terms(args.vocabulary))
        finally:
            con.close()
        log(f"built the dataset in {data}")
    summary_path = data / "dataset.json"
    if not summary_path.exists():
        raise ModelError(f"{data} has no dataset.json; build it with: irudd-voice dataset build --out {data}")
    examples = json.loads(summary_path.read_text())["examples"]
    if not examples["train"] or not examples["selection"]:
        raise ModelError(f"the dataset has {examples['train']} training and {examples['selection']} selection "
                         "examples; training needs both. Label more thoughts (on more days), then build it again.")
    con = db.connect(path)
    try:
        model_id = train.next_model_id(cand, args.models_dir, con)
    finally:
        con.close()
    settings = run_settings(examples["train"], args.iterations)
    lower_priority(log)
    with appstate.UnloadLease(path, log=log) as lease:
        log(f"going ahead: {lease.wait_for_app()}")
        result = train.train_dataset(cand, data, model_id, models_dir=args.models_dir, settings=settings, log=log)
    models.record(path, result.manifest)
    log(f"recorded {model_id} in {path}. Next: irudd-voice eval-compare {model_id}")
    print(json.dumps({"model_id": model_id, "folder": str(result.folder), "timings": result.timings,
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


@reports_errors
def status_command(args) -> int:
    from . import promote

    return promote.status_command(args)


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
    status = models_commands.add_parser("status", help="the active model, its score and what the app has loaded")
    status.add_argument("--db", type=Path, default=argparse.SUPPRESS, help="database file (default: the app's)")
    status.set_defaults(run=status_command)

    train = commands.add_parser("train", help="fine-tune a candidate with LoRA on your labeled thoughts "
                                              "(needs --group ml)")
    train.add_argument("candidate", nargs="?", help=CANDIDATE_HELP + " (default: the active model's, else "
                                                    "gemma-4-e2b)")
    train.add_argument("--candidate", dest="candidate_option", metavar="CANDIDATE", help="same as the argument")
    train.add_argument("--dataset", type=Path, help="a dataset build folder (default: build one now)")
    train.add_argument("--iterations", type=int, help="LoRA steps (default: two passes over the training "
                                                      "examples, 100 to 1000)")
    train.add_argument("--vocabulary", type=Path, default=VOCABULARY_PATH,
                       help="vocabulary for the dataset build (default: the app's)")
    train.add_argument("--tiny", action="store_true", help="40 synthetic examples, to check the training round trip")
    train.add_argument("--models-dir", type=Path, default=DEFAULT_MODELS_DIR,
                       help="where model folders go (default: the app's)")
    train.add_argument("--db", type=Path, default=argparse.SUPPRESS,
                       help="database (default: the app's). With --tiny: where to record the test model "
                            "(default: nowhere, so test models stay out of the app's database)")
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
