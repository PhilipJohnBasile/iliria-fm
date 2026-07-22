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
import urllib.error
import urllib.request

DEFAULT_PROMPTS = [
    "In one sentence, explain what the apex of a corner is in motor racing.",
    "List three prime numbers greater than fifty.",
    "Write a two-line haiku about fast NVMe storage.",
]


def run_once(base_url, model, prompt, api_key, max_tokens, ask_usage=True):
    url = base_url.rstrip("/") + "/v1/chat/completions"
    body = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "stream": True,
        "max_tokens": max_tokens,
    }
    # Ask for the token count rather than inferring one. Without this a server may stream
    # content and never send `usage`, leaving only SSE chunks to count -- which are not
    # tokens. Not every server accepts the field, so a rejection falls back once.
    if ask_usage:
        body["stream_options"] = {"include_usage": True}
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
    # Token count must come from the server's own `usage`. Falling back to counting SSE
    # chunks silently reports chunks/sec as tokens/sec whenever a stream omits usage --
    # a units swap that looks like a plausible number. Record WHICH source was used so
    # the caller can refuse to publish an unverified rate.
    if completion_tokens:
        tokens, token_source = completion_tokens, "usage"
    else:
        tokens, token_source = chunk_count, "chunks"
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
        "token_source": token_source,
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
    ap.add_argument("--allow-chunk-estimate", action="store_true",
                    help="report a rate even when the server sends no usage block, by "
                         "counting SSE content chunks. Chunks are NOT tokens -- the result "
                         "is labelled chunk/s and must never be published as tok/s.")
    args = ap.parse_args()

    if args.prompt:
        prompts = [args.prompt] * args.n
    else:
        prompts = (DEFAULT_PROMPTS * (args.n // len(DEFAULT_PROMPTS) + 1))[: args.n]
    rows = []
    ask_usage = True
    print(f"# {args.label or args.model} @ {args.base_url}  "
          f"(model={args.model}, max_tokens={args.max_tokens})")
    print(f"{'run':>3}  {'ttft_s':>8}  {'total_s':>8}  {'tokens':>6}  {'tok/s':>7}  note")
    for i, prompt in enumerate(prompts, 1):
        try:
            r = run_once(args.base_url, args.model, prompt, args.api_key, args.max_tokens,
                         ask_usage=ask_usage)
        except urllib.error.HTTPError as exc:
            if exc.code == 400 and ask_usage:
                # Server rejects `stream_options`; drop it for this and all later runs.
                ask_usage = False
                print(f"{i:>3}  note: server rejected stream_options, retrying without it")
                try:
                    r = run_once(args.base_url, args.model, prompt, args.api_key,
                                 args.max_tokens, ask_usage=False)
                except Exception as exc2:  # noqa: BLE001
                    print(f"{i:>3}  ERROR: {exc2}")
                    continue
            else:
                print(f"{i:>3}  ERROR: {exc}")
                continue
        except Exception as exc:  # noqa: BLE001 -- benchmark tool, report and continue
            print(f"{i:>3}  ERROR: {exc}")
            continue
        rows.append(r)
        # A per-run rate is only a token rate if the count came from `usage`. Printing an
        # unverified one under a "tok/s" header is the units swap this gate exists to stop.
        if r["token_source"] == "usage" or args.allow_chunk_estimate:
            rate = f"{r['tok_s']:>7.1f}"
        else:
            rate = f"{'--':>7}"
        note = r["note"]
        if r["token_source"] != "usage":
            note = (note + "  " if note else "") + f"[{r['tokens']} chunks, no usage]"
        print(f"{i:>3}  {r['ttft']:>8.3f}  {r['total']:>8.3f}  {r['tokens']:>6}  "
              f"{rate}  {note}")

    if rows:
        # Only rows whose count came from the server's `usage` are a real token rate.
        # Anything else is a chunk rate wearing the same units, so it is withheld rather
        # than averaged in -- a wrong number is worse than a missing one.
        counted = [r for r in rows if r["token_source"] == "usage"]
        estimated = [r for r in rows if r["token_source"] != "usage"]
        if counted:
            rate = f"tok/s={statistics.median(r['tok_s'] for r in counted):.1f}"
        elif args.allow_chunk_estimate:
            rate = f"chunk/s={statistics.median(r['tok_s'] for r in rows):.1f} (NOT tok/s)"
        else:
            rate = "tok/s=WITHHELD"
        print(
            f"\nmedian  ttft={statistics.median(r['ttft'] for r in rows):.3f}s  "
            f"total={statistics.median(r['total'] for r in rows):.3f}s  "
            f"{rate}  (n={len(counted) if counted else len(rows)})"
        )
        if estimated:
            print(f"        {len(estimated)}/{len(rows)} run(s) sent no usage block; their "
                  f"'tokens' column counts SSE chunks, not tokens.")
            if not counted and not args.allow_chunk_estimate:
                print("        No run reported usage -> no token rate can be computed. "
                      "Re-run with stream_options={'include_usage': true} if the server "
                      "supports it, or pass --allow-chunk-estimate for a labelled "
                      "chunk rate. Do not publish the tokens column as tok/s.")
        # Runs that produced nothing would otherwise drag the medians down invisibly.
        empty = [r for r in rows if r["tokens"] == 0]
        if empty:
            reasons = {r["note"] for r in empty}
            print(f"        {len(empty)}/{len(rows)} run(s) produced no content -> "
                  + "; ".join(sorted(reasons)))


if __name__ == "__main__":
    main()
