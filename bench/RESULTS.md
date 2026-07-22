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
| **fm local** | Apple `system` | ANE | 0.548 s | 19.4 | 5 |
| **fm cloud** | Apple `pcc` | Private Cloud Compute | — | — | HTTP 503 |
| **iliria** | GLM-5.2 744B MoE | Metal GPU + NVMe | ~37 s | ~0.5 | 1 |

- **trailbrake is the throughput/latency winner** — fastest to first token (0.23 s) and
  highest decode rate, even while sharing the GPU with a resident iliria.
- **fm local is a genuinely useful tier-0**: ~19 tok/s at 0.55 s TTFT, on the **ANE**, so it
  costs nothing on the Metal GPU or NVMe that the other tiers need. Free and private.
- **fm cloud returns `HTTP 503`** — `fm available` reports *"PCC inference is not available
  in this context"*. Private Cloud Compute requires the
  `com.apple.developer.private-cloud-compute` entitlement/eligibility; the wiring is
  identical to `system`, so this row fills in once that lands.
- **iliria is the deep, slow escalation** — ~40–70× the TTFT of the fast tiers. Exactly why
  it should serve only the hard minority of requests.

## Through the racecontrol router

| path | TTFT | tok/s | n |
|---|---|---|---|
| racecontrol → trailbrake | 1.27 s | 26.7 | 4 |
| racecontrol → trailbrake (`#deep`) | 1.64 s | 24.3 | 4 |

Throughput through the router matches direct (23–27 tok/s), i.e. **the router adds no
meaningful decode overhead**.

### Two findings worth chasing

1. **No incremental streaming observed through the router.** On every routed run
   `TTFT == total` (e.g. 1.272 s / 1.272 s), while direct engine runs show a normal split
   (0.228 s / 1.946 s). The whole response arrives at once. Either racecontrol buffers its
   SSE relay or the client buffers the router's chunked framing — worth disambiguating with
   a raw-socket read, since streaming UX depends on it.

2. **Tier selection did not honor `default_tier` in this config.** With both backends up,
   requests were attributed (`X-Router-Backend`) to `trailbrake`/`fast` even with
   `default_tier = "edge"`, with `policy = "edge"` (whose comment says a tier name "pins all
   traffic to it"), and with `enable_task_heuristic = false`. Routing to fm **does** work —
   with trailbrake stopped, the same request returned `X-Router-Backend: fm-system`,
   `X-Router-Tier: edge`, HTTP 200 — so the edge path is functional, but it could not be
   isolated while the fast tier was healthy. A clean router→fm number is therefore **not
   reported here** rather than guessed at.

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
