#!/usr/bin/env python3
"""Tiny streaming benchmark for any OpenAI-compatible /v1/chat/completions endpoint.

Covers every tier of the stack with one tool: Apple `fm serve` (system / pcc),
trailbrake, iliria, and the racecontrol router. Measures time-to-first-token (TTFT),
total latency, and decode tokens/sec. Pure stdlib — no dependencies.

  python3 bench.py --base-url http://127.0.0.1:8898 --model system      # Apple on-device
  python3 bench.py --base-url http://127.0.0.1:8080 --model default     # trailbrake
  python3 bench.py --base-url http://127.0.0.1:8000 --model glm-5.2-iliria
  python3 bench.py --base-url http://127.0.0.1:8100 --model default     # racecontrol
"""
import argparse
import json
import statistics
import time
import urllib.request

DEFAULT_PROMPTS = [
    "In one sentence, explain what the apex of a corner is in motor racing.",
    "List three prime numbers greater than fifty.",
    "Write a two-line haiku about fast NVMe storage.",
]


def run_once(base_url, model, prompt, api_key, max_tokens):
    url = base_url.rstrip("/") + "/v1/chat/completions"
    body = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "stream": True,
        "max_tokens": max_tokens,
    }
    req = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST")
    req.add_header("Content-Type", "application/json")
    if api_key:
        req.add_header("Authorization", f"Bearer {api_key}")

    start = time.perf_counter()
    ttft = None
    chunk_count = 0
    completion_tokens = None
    finish_reason = None
    refusal = None
    with urllib.request.urlopen(req, timeout=600) as resp:
        for raw in resp:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            payload = line[len("data:"):].strip()
            if payload == "[DONE]":
                break
            try:
                chunk = json.loads(payload)
            except json.JSONDecodeError:
                continue
            choices = chunk.get("choices") or [{}]
            first = choices[0] if choices else {}
            delta_obj = first.get("delta") or {}
            delta = delta_obj.get("content")
            # A model may decline instead of generating. Capture it, so a zero-token run
            # reads as "refused"/"stopped early" rather than looking like a broken request.
            if delta_obj.get("refusal"):
                refusal = delta_obj["refusal"]
            if first.get("finish_reason"):
                finish_reason = first["finish_reason"]
            if delta:
                if ttft is None:
                    ttft = time.perf_counter() - start
                chunk_count += 1
            usage = chunk.get("usage")
            if usage and usage.get("completion_tokens"):
                completion_tokens = usage["completion_tokens"]

    total = time.perf_counter() - start
    tokens = completion_tokens if completion_tokens else chunk_count
    if refusal:
        note = f"refused: {str(refusal)[:44]}"
    elif tokens == 0:
        note = f"no content (finish_reason={finish_reason})"
    else:
        note = ""
    return {
        "ttft": ttft if ttft is not None else total,
        "total": total,
        "tokens": tokens,
        "tok_s": tokens / total if total > 0 else 0.0,
        "finish": finish_reason,
        "refusal": refusal,
        "note": note,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--base-url", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--api-key", default=None)
    ap.add_argument("--n", type=int, default=len(DEFAULT_PROMPTS), help="number of requests")
    ap.add_argument("--max-tokens", type=int, default=128)
    ap.add_argument("--prompt", default=None,
                    help="use this single prompt for every run (overrides the built-in set); "
                         "handy for forcing a router escalation marker such as '#deep ...'")
    ap.add_argument("--label", default=None, help="label printed in the header")
    args = ap.parse_args()

    if args.prompt:
        prompts = [args.prompt] * args.n
    else:
        prompts = (DEFAULT_PROMPTS * (args.n // len(DEFAULT_PROMPTS) + 1))[: args.n]
    rows = []
    print(f"# {args.label or args.model} @ {args.base_url}  "
          f"(model={args.model}, max_tokens={args.max_tokens})")
    print(f"{'run':>3}  {'ttft_s':>8}  {'total_s':>8}  {'tokens':>6}  {'tok/s':>7}  note")
    for i, prompt in enumerate(prompts, 1):
        try:
            r = run_once(args.base_url, args.model, prompt, args.api_key, args.max_tokens)
        except Exception as exc:  # noqa: BLE001 -- benchmark tool, report and continue
            print(f"{i:>3}  ERROR: {exc}")
            continue
        rows.append(r)
        print(f"{i:>3}  {r['ttft']:>8.3f}  {r['total']:>8.3f}  {r['tokens']:>6}  "
              f"{r['tok_s']:>7.1f}  {r['note']}")

    if rows:
        print(
            f"\nmedian  ttft={statistics.median(r['ttft'] for r in rows):.3f}s  "
            f"total={statistics.median(r['total'] for r in rows):.3f}s  "
            f"tok/s={statistics.median(r['tok_s'] for r in rows):.1f}  (n={len(rows)})"
        )
        # Runs that produced nothing would otherwise drag the medians down invisibly.
        empty = [r for r in rows if r["tokens"] == 0]
        if empty:
            reasons = {r["note"] for r in empty}
            print(f"        {len(empty)}/{len(rows)} run(s) produced no content -> "
                  + "; ".join(sorted(reasons)))


if __name__ == "__main__":
    main()
