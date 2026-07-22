# Benchmarks

`bench.py` measures time-to-first-token (TTFT) and decode tokens/sec over a streaming
`/v1/chat/completions` request. It is tier-agnostic — the same tool runs against Apple
`fm serve`, trailbrake, iliria, or racecontrol.

## Apple on-device (`fm serve`, `model=system`) — Apple Neural Engine

M5 Max, macOS 27 beta, `fm serve` on :8898, 5 runs, `max_tokens=64`:

| metric | median |
|---|---|
| TTFT   | 0.56 s |
| total  | 1.26 s |
| decode | ~14 tok/s |

Runs on the **ANE** — free, private, and *off* the Metal GPU the stack's own engines use.
That's what makes Apple's on-device model a viable **tier-0** in front of trailbrake/iliria
(cheap/short/structured work never touches the GPU or NVMe-streamed expert tiers).

Reproduce:

```bash
racecontrol-fm/fm-serve.sh &                                      # fm serve :8898
python3 bench/bench.py --base-url http://127.0.0.1:8898 --model system --n 5
```

## Full cross-tier

The harness covers every tier; to compare, start each engine and point `--model` at what it
actually serves:

```bash
python3 bench/bench.py --base-url http://127.0.0.1:8080 --model default        # trailbrake (Metal)
python3 bench/bench.py --base-url http://127.0.0.1:8000 --model <ili --model-id> # iliria (deep)
python3 bench/bench.py --base-url http://127.0.0.1:8100 --model default         # via racecontrol
```

> Note: benchmarking the deep tier (iliria, ~1.6 tok/s) or a GPU engine while other GPU
> work is running will contend for the Metal GPU — run those when the GPU is free.
