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
| cloud | `pcc` | Private Cloud Compute | Larger context + stronger reasoning. Requires `fm serve` to be launched from **Terminal.app** — PCC is gated by *process context*, not an entitlement. Otherwise `fm available` reports it unavailable and the router's circuit breaker holds that backend open (with `fallback` keeping requests served). |

## Verified

On-device, end-to-end through `fm serve` on this machine:

```
$ curl -s localhost:8898/v1/chat/completions -d \
    '{"model":"system","messages":[{"role":"user","content":"Reply with exactly the word: OK"}],"stream":false}'
{"object":"chat.completion","model":"system","choices":[{"finish_reason":"stop",
 "message":{"content":"OK","role":"assistant"}}],"usage":{"total_tokens":61,...}}
```

**Private Cloud Compute needs `fm serve` started from Terminal.app.** Run from any other
process context, `fm` refuses PCC with *"Private Cloud Compute is not available in this
context. Please use the Terminal app."* — this is a process-attribution gate, **not** an
entitlement. Launched from Terminal.app, `/health` reports both models available:

```
{"models":[{"name":"system","available":true},{"name":"pcc","available":true}]}
```

Only the *server's* context matters, so racecontrol (or any HTTP client) reaches PCC normally
once `fm serve` is running that way.

## Why this respects racecontrol's design

`fm serve` is a separate process (Apple's own binary). racecontrol reaches it over HTTP
like any other backend, so its dependency-free, portable Python core is untouched — the
Apple tiers exist only in *your* config file, and only on macOS.
