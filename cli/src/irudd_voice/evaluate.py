"""`irudd-voice eval`: run a model folder over the fixed sets in evals/.

Each item goes through the shared prompt, greedy generation, the reply
parser and the hard checks, exactly as the app would. Transcripts are also
scored for closeness to the expected output. The report is JSON so the
baseline pick and later promotion can compare models.
"""

from __future__ import annotations

import hashlib
from collections import Counter
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from statistics import mean

from . import hardchecks, pieces
from . import prompt as cleanup_prompt
from .generation import read_jsonl
from .models import utc_now

EVALS = Path(__file__).resolve().parents[3] / "evals"
SETS = ("questions", "transcripts")


@dataclass
class Output:
    text: str
    hit_limit: bool
    seconds: float
    timed_out: bool = False  # stopped at the prompt's deadline (generation.timeout_seconds)


# transcript, vocabulary terms -> what the model generated
Generator = Callable[[str, list[str]], Output]


def set_path(name: str) -> Path:
    return EVALS / f"{name}.jsonl"


def edit_distance(a: str, b: str) -> int:
    previous = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        current = [i]
        for j, cb in enumerate(b, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (ca != cb)))
        previous = current
    return previous[-1]


def similarity(a: str, b: str) -> float:
    """1 - character edit distance / length of the longer text. 1.0 = same."""
    a, b = a.strip(), b.strip()
    if not a and not b:
        return 1.0
    return 1 - edit_distance(a, b) / max(len(a), len(b))


def percentile(values: list[float], p: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, round(p / 100 * (len(ordered) - 1)))]


def score_item(item: dict, out: Output, prompt: dict) -> dict:
    terms = item.get("vocabulary", [])[: prompt["vocabulary_limit"]]
    if out.timed_out:
        reply = hardchecks.Reply(None, "timeout")
    else:
        reply = hardchecks.parse_reply(out.text, hit_limit=out.hit_limit, key=prompt["output_key"])
    if reply.cleaned is None:
        failures = [reply.failure]
    else:
        checks = prompt["checks"]
        failures = hardchecks.check(item["transcript"], reply.cleaned, terms,
                                    checks["max_output_words_ratio"], checks["max_output_words_slack"])
    pasted = reply.cleaned if not failures else item["transcript"]
    result = {
        "id": item["id"],
        "transcript": item["transcript"],
        "reply": out.text,
        "cleaned": reply.cleaned,
        "failures": failures,
        "seconds": round(out.seconds, 3),
    }
    if "expected" in item:
        result["expected"] = item["expected"]
        result["similarity"] = None if reply.cleaned is None else round(similarity(reply.cleaned, item["expected"]), 4)
        result["pasted_similarity"] = round(similarity(pasted, item["expected"]), 4)
    return result


def score_thought(item: dict, generate: Generator, prompt: dict) -> dict:
    """One thought cleaned the way the app cleans it (ThoughtCleaner.swift):
    split into pieces, each piece generated and hard-checked on its own,
    stopping at the first piece that fails. The cleaned pieces are joined
    with a space. On any failure, or when nothing is left, the raw
    transcript is pasted. `cleaned` joins the model's text for the pieces
    it got to, so a report can still show what the model said."""
    terms = item.get("vocabulary", [])
    parts = pieces.split(item["transcript"])
    cleaned: list[str] = []
    failures: list[str] = []
    seconds = 0.0
    for piece in parts:
        scored = score_item({"id": item["id"], "transcript": piece, "vocabulary": terms},
                            generate(piece, terms), prompt)
        seconds += scored["seconds"]
        if scored["cleaned"] is not None:
            cleaned.append(scored["cleaned"])
        if scored["failures"]:
            failures = scored["failures"]
            break
    joined = " ".join(text for text in cleaned if text)
    if not failures and not joined:
        failures = ["empty"]
    return {
        "cleaned": joined if cleaned else None,
        "failures": failures,
        "pasted": item["transcript"] if failures else joined,
        "seconds": round(seconds, 3),
        "pieces": len(parts),
    }


def summarize(results: list[dict]) -> dict:
    seconds = [r["seconds"] for r in results]
    failures = Counter(f for r in results for f in r["failures"])
    summary = {
        "items": len(results),
        "passed": sum(not r["failures"] for r in results),
        "with_failures": sum(bool(r["failures"]) for r in results),
        "failures_by_check": dict(sorted(failures.items())),
        "seconds_p50": percentile(seconds, 50),
        "seconds_p90": percentile(seconds, 90),
        "seconds_max": max(seconds) if seconds else None,
    }
    scored = [r["similarity"] for r in results if r.get("similarity") is not None]
    if any("expected" in r for r in results):
        summary["mean_similarity"] = round(mean(scored), 4) if scored else None
        summary["mean_pasted_similarity"] = round(mean(r["pasted_similarity"] for r in results), 4)
        summary["exact"] = sum(r.get("cleaned") == r["expected"] for r in results)
    return summary


def run(generate: Generator, sets: list[str], prompt: dict | None = None, log=print) -> dict:
    prompt = prompt or cleanup_prompt.load()
    report_sets = {}
    for name in sets:
        path = set_path(name)
        results = []
        for item in read_jsonl(path):
            result = score_item(item, generate(item["transcript"], item.get("vocabulary", [])), prompt)
            log(f"{result['id']}: {result['seconds']:.2f} s {','.join(result['failures']) or 'ok'}")
            results.append(result)
        report_sets[name] = {
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "summary": summarize(results),
            "items": results,
        }
    gate = {}
    if "questions" in report_sets:
        gate["questions_with_failures"] = report_sets["questions"]["summary"]["with_failures"]
    if "transcripts" in report_sets:
        gate["transcripts_with_failures"] = report_sets["transcripts"]["summary"]["with_failures"]
    if len(gate) == 2:
        # Baseline gate (plan step 1c), hard-check part only; speed is
        # measured separately through the app's helper.
        gate["passes_hard_checks"] = gate["questions_with_failures"] == 0 and gate["transcripts_with_failures"] <= 5
    return {"prompt_version": prompt["version"], "sets": report_sets, "hard_check_gate": gate}


def evaluate_folder(folder: Path, sets: list[str], log=print) -> dict:
    from .generation import Model, contract_hashes, hardware, package_version

    model = Model(folder)
    model.clean("warm up")  # the first call compiles kernels; keep it out of the timings

    def generate(transcript: str, terms: list[str]) -> Output:
        gen = model.clean(transcript, terms)
        return Output(gen.text, gen.hit_limit, gen.seconds)

    report = run(generate, sets, model.prompt, log)
    return {
        "model_id": model.manifest["id"],
        "manifest_sha256": hashlib.sha256((folder / "manifest.json").read_bytes()).hexdigest(),
        **contract_hashes(),
        "hardware": hardware(),
        "mlx_version": package_version("mlx"),
        "mlx_lm_version": package_version("mlx-lm"),
        "created_at": utc_now(),
        **report,
    }
