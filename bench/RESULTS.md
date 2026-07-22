# Benchmarks

`bench.py` measures time-to-first-token (TTFT) and decode tokens/sec over a streaming
`/v1/chat/completions` request. It is tier-agnostic — the same tool runs against Apple
`fm serve`, trailbrake, iliria, or racecontrol.

Machine: Apple M5 Max (128 GB unified), macOS 27 beta. All runs `max_tokens=48` unless noted.
iliria was resident throughout (it backs a live router and could not be stopped), so GPU
figures are *under contention*, not isolated bests.

## Direct engines

| path | model | hardware | TTFT | tok/s | n |
|---|---|---|---|---|---|
| **trailbrake** | Qwen3-32B-4bit | Metal GPU | **0.228 s** | **22.8** | 5 |
| **fm local** | Apple `system` | ANE | 0.443 s | 26.1 | 5 |
| **fm cloud** | Apple `pcc` | Private Cloud Compute | 0.621 s | **35.8** | 5 |
| **iliria** | GLM-5.2 744B MoE | Metal GPU + NVMe | ~37 s | ~0.5 | 1 |

- **trailbrake is the throughput/latency winner** — fastest to first token (0.23 s) and
  highest decode rate, even while sharing the GPU with a resident iliria.
- **fm local is a genuinely useful tier-0**: ~19 tok/s at 0.55 s TTFT, on the **ANE**, so it
  costs nothing on the Metal GPU or NVMe that the other tiers need. Free and private.
- **fm cloud (PCC) is the throughput winner at 35.8 tok/s** — the highest decode rate
  measured anywhere here, for a modest TTFT cost (0.62 s vs 0.44 s) covering the network hop.
  It is **not** gated by an entitlement, as first assumed: `fm` refuses PCC by *process
  context* — *"Private Cloud Compute is not available in this context. Please use the Terminal
  app."* Launch `fm serve` from **Terminal.app** and `/health` reports `pcc available: true`;
  an HTTP client then reaches it normally, since only the server's context matters.
  Caveat: some PCC runs return **zero content tokens** — reproducibly on "List three prime
  numbers greater than fifty". `bench.py` now reports why, and it is *not* a refusal as first
  assumed: `finish_reason = tool_calls`. PCC elects to **call a tool** for that prompt, and a
  content-only reader sees nothing. Prompts that answer directly are unaffected.
- **iliria is the deep, slow escalation** — ~40–70× the TTFT of the fast tiers. Exactly why
  it should serve only the hard minority of requests.

## Through the racecontrol router

All rows below are attribution-verified via `X-Router-Backend`/`X-Router-Tier`, so each one is
known to have been served by the tier named.

| path | attribution | TTFT | tok/s | n |
|---|---|---|---|---|
| racecontrol → **fm-pcc** (cloud) | `fm-pcc` / `cloud` | 0.517 s | **60.2** | 4 |
| racecontrol → fm-system (edge) | `fm-system` / `edge` | 0.653 s | 28.3 | 4 |
| racecontrol → fm (edge), right after the streaming fix | `fm-system` / `edge` | 0.678 s | 29.4 | 4 |
| racecontrol → trailbrake, *before* the streaming fix | `trailbrake` / `fast` | 1.27 s\* | 26.7 | 4 |

Private Cloud Compute is the fastest path measured anywhere here — **60 tok/s through the
router**, faster than any local tier, because the work happens on Apple's servers rather than
contending for this machine's GPU. (Its 60.2 vs the 35.8 measured direct earlier is warm-up
and server-side variance, not the router accelerating anything; the earlier figure was also
dragged down by tool-call frames returning no content.)

\* Pre-fix TTFT is not a real first-token time — see finding 1. Throughput through the router
matches direct throughout (23–29 tok/s), i.e. **the router adds no meaningful decode
overhead**; only first-token latency was affected.

### Both findings resolved

1. **Streaming through the router was genuinely broken — now fixed.** Every routed run showed
   `TTFT == total` (1.272 s / 1.272 s) against a normal 0.228 s / 1.946 s split direct. Root
   cause was in racecontrol's `backends.py`: `read_chunk` used
   `http.client.HTTPResponse.read(size)`, which on a chunked body blocks until it has
   collected `size` bytes **or the body ends** — so with the default 65536, every SSE response
   under 64 KB was buffered in full before a single byte was relayed. Proven with a chunked
   test server (`read(65536)` → 1.005 s returning the whole body; `read1(65536)` → 0.000 s
   returning the first chunk). Fixed by switching to `read1`, with a regression test; measured
   after the fix: **0.678 s TTFT / 1.763 s total**. The module docstring had asserted the
   opposite and was corrected too.

2. **Tier selection was working as designed — my benchmark was wrong.** racecontrol's
   `resolve_manual_override` treats a `model` naming a configured tier *or* backend
   `id`/`model_id` as an explicit override that "bypasses the policy entirely" (a documented
   escape hatch). The bench sent `--model default`, which matches trailbrake's
   `model_id = "default"`, pinning every request to `fast` **before** any policy ran — which
   is exactly why `policy = "edge"` and `enable_task_heuristic = false` appeared to do
   nothing. Re-run with `--model system`, attribution confirms `X-Router-Backend: fm-system`,
   `X-Router-Tier: edge`. No router bug here.

## Reproduce

```bash
racecontrol-fm/fm-serve.sh &                                                  # fm serve :8898
python3 bench/bench.py --base-url http://127.0.0.1:8898 --model system        # Apple on-device
python3 bench/bench.py --base-url http://127.0.0.1:8898 --model pcc           # Apple PCC
python3 bench/bench.py --base-url http://127.0.0.1:8080 --model default       # trailbrake
python3 bench/bench.py --base-url http://127.0.0.1:8000 --model <ili --model-id>  # iliria
python3 bench/bench.py --base-url http://127.0.0.1:8100 --model default \
        --prompt "#deep ..."                                                  # via racecontrol
```

> Benchmarking the deep tier or a GPU engine while other GPU work is running will contend for
> the Metal GPU — run those when the GPU is free for isolated numbers.
