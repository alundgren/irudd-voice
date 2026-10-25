"""Tie-aware parity report: how close was Python to picking Swift's token?

For each input where the Swift tokens differ from the Python reference,
replays the reference with Python mlx-lm up to the first differing token
(the same way generate_step feeds it: all prompt tokens but the last, then
one token at a time) and prints the logits of Python's and Swift's tokens at
that step. The tie-aware rule (accepted by the project owner on 2026-10-25)
passes when the prompt tokens are identical everywhere and, at every
difference, Swift's token is among Python's top 3 choices and within
--max-gap of Python's first choice in Python's own logits. Top 3 rather than
second: when Python's top two tie exactly, a near-tie third is just as
legitimate a pick.

    python parity-gaps.py MODEL_DIR REFERENCE.json SWIFT.json [--max-gap 0.5]

Needs mlx and mlx-lm (the CLI's `ml` group). Loads the model: hold the
heavy-job lock on a shared Mac. Exit code 0 when the tie-aware rule passes.
"""

import argparse
import json
import sys

import mlx.core as mx
from mlx_lm import load
from mlx_lm.models.cache import make_prompt_cache


def first_difference(a: list[int], b: list[int]) -> int | None:
    for index, (x, y) in enumerate(zip(a, b)):
        if x != y:
            return index
    return None if len(a) == len(b) else min(len(a), len(b))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("model")
    parser.add_argument("reference")
    parser.add_argument("swift")
    parser.add_argument("--max-gap", type=float, default=0.5)
    args = parser.parse_args()

    reference = json.load(open(args.reference))
    swift = {item["id"]: item for item in json.load(open(args.swift))["items"]}
    stops = set(reference["stop_token_ids"])
    ok = True
    differences = []
    for item in reference["items"]:
        other = swift.get(item["id"])
        if other is None or other["prompt_token_ids"] != item["prompt_token_ids"]:
            print(f"{item['id']}: prompt tokens differ or missing; the tie-aware rule needs identical prompts")
            ok = False
            continue
        # The stop token is the last "generated" token on each side.
        python = item["generated_token_ids"] + ([item["stop_token_id"]] if item["stop_token_id"] is not None else [])
        ours = other["generated_token_ids"] + ([other["stop_token_id"]] if other["stop_token_id"] is not None else [])
        index = first_difference(python, ours)
        if index is not None:
            differences.append((item, python, ours, index))

    if differences:
        model, tokenizer = load(args.model)
    for item, python, ours, index in differences:
        if index >= len(python) or index >= len(ours):
            print(f"{item['id']}: one side stopped at token {index} by length; no logit gap to compare")
            ok = False
            continue
        prompt = item["prompt_token_ids"]
        cache = make_prompt_cache(model)
        model(mx.array(prompt[:-1])[None], cache=cache)
        mx.eval([c.state for c in cache])
        token = prompt[-1]
        for step in range(index + 1):
            logits = model(mx.array([[token]]), cache=cache)[0, -1].astype(mx.float32)
            mx.eval(logits)
            if step < index:
                token = python[step]
        order = mx.argsort(-logits)
        top = int(order[0].item())
        top3 = [int(order[i].item()) for i in range(3)]
        a, b = python[index], ours[index]
        gap = logits[a].item() - logits[b].item()
        within = gap <= args.max_gap
        near = b in top3
        ok = ok and within and top == a and near
        print(
            f"{item['id']}: token {index}: python {a} {tokenizer.decode([a])!r} {logits[a].item():.4f}, "
            f"swift {b} {tokenizer.decode([b])!r} {logits[b].item():.4f}, gap {gap:.4f} "
            f"({'within' if within else 'over'} {args.max_gap})"
            + ("" if top == a else f"; replay picked {top}, not Python's token")
            + ("" if near else f"; Swift's token isn't in Python's top 3 ({top3})")
            + (" [stop token]" if a in stops or b in stops else "")
        )
    total = len(reference["items"])
    summary = f"{total - len(differences)} of {total} identical"
    if ok:
        print(f"tie-aware ({reference['model_id']}): OK: {summary}, {len(differences)} within a gap of {args.max_gap}")
    else:
        print(f"tie-aware ({reference['model_id']}): FAIL: {summary}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
