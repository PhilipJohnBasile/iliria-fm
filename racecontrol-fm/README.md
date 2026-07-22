# racecontrol ⇄ Apple Foundation Models

Direction **B**: use Apple's on-device and Private Cloud Compute models *as tiers*
inside the racecontrol router — no changes to racecontrol's dependency-free core.

Apple's `fm` CLI ships a built-in Chat Completions server, so this is config, not code:

```
fm serve  →  OpenAI /v1/chat/completions exposing model_id "system" and "pcc"
             ▲
racecontrol ─┘  (a [[backends]] entry per model_id)
```

## Run it

```bash
./fm-serve.sh                                   # starts `fm serve` on :8898
racecontrol check-config --config router.fm.example.toml
racecontrol serve --config router.fm.example.toml
```

`fm-serve.sh` prints `fm available` first, so you can see which models this machine
can actually run.

## Local and cloud

| Tier | racecontrol `model_id` | Runs on | Notes |
|---|---|---|---|
| on-device (local) | `system` | Apple Neural Engine | Free, private, off your Metal GPU. Available whenever Apple Intelligence is on. |
| cloud | `pcc` | Private Cloud Compute | Larger context + stronger reasoning. Needs the `com.apple.developer.private-cloud-compute` entitlement/eligibility — until then `fm available` reports it unavailable and the router's circuit breaker holds that backend open (with `fallback` keeping requests served). |

## Verified

On-device, end-to-end through `fm serve` on this machine:

```
$ curl -s localhost:8898/v1/chat/completions -d \
    '{"model":"system","messages":[{"role":"user","content":"Reply with exactly the word: OK"}],"stream":false}'
{"object":"chat.completion","model":"system","choices":[{"finish_reason":"stop",
 "message":{"content":"OK","role":"assistant"}}],"usage":{"total_tokens":61,...}}
```

`pcc` returns `available:false — "PCC inference is not available in this context"` here,
which is the expected state until the entitlement is in place; the wiring is identical.

## Why this respects racecontrol's design

`fm serve` is a separate process (Apple's own binary). racecontrol reaches it over HTTP
like any other backend, so its dependency-free, portable Python core is untouched — the
Apple tiers exist only in *your* config file, and only on macOS.
