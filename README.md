# iliria-fm

Apple [Foundation Models](https://developer.apple.com/documentation/foundationmodels)
integration for the **iliria stack** — the two-tier local-LLM family of
[iliria](https://github.com/PhilipJohnBasile/iliria) (deep),
[trailbrake](https://github.com/PhilipJohnBasile/trailbrake) (fast), and
[racecontrol](https://github.com/PhilipJohnBasile/racecontrol) (router).

It connects the stack to macOS 27's Foundation Models framework in **both directions**,
and mirrors Apple's own **local (on-device) / cloud (Private Cloud Compute)** split.

> **⚠️ Experimental / beta.** Targets the macOS 27 **beta** SDK; APIs may change before
> GA and there are no production or GA-compatibility guarantees. See each direction's
> notes on entitlements before shipping an app on it.

## Direction A — our engines → any FM app

A SwiftPM package (`IliriaFoundationModels`) that implements the framework's
custom-provider protocols (`LanguageModel` + `LanguageModelExecutor`) and forwards to an
engine's OpenAI-compatible HTTP endpoint, streaming token deltas back into the framework.
Any macOS 27 app can then select an iliria-stack engine through the standard
`LanguageModelSession` API — the same way it selects Apple's own model.

```swift
import FoundationModels
import IliriaFoundationModels

let session = LanguageModelSession(model: IliriaLanguageModel.local())   // trailbrake
let reply = try await session.respond(to: "Summarize this in one line: …")
```

| Factory | Engine | Default | Apple analogue |
|---|---|---|---|
| `.local()` | trailbrake (fast, Metal) | `:8080` | `SystemLanguageModel` |
| `.cloud()` | iliria (deep, GLM-5.2) | `:8000` | `PrivateCloudComputeLanguageModel` |
| `.routed()` | racecontrol | `:8100` | — |

Forwards only to *your own* engines — no Apple model, no entitlement. v1 is text-only and
throws a typed `IliriaEngineError.unsupportedFeature` if a request needs tools or guided
generation, rather than silently dropping them. Build: `swift build` (Xcode 27 / macOS 27).

## Direction B — Apple's FM → our router

Use Apple's **on-device** and **Private Cloud Compute** models *as tiers* inside
racecontrol, with no changes to the router's dependency-free core. Apple's `fm` CLI ships
a Chat Completions server, so this is config only — see [`racecontrol-fm/`](racecontrol-fm/):

```bash
racecontrol-fm/fm-serve.sh                                            # `fm serve` on :8898
racecontrol serve --config racecontrol-fm/router.fm.example.toml     # system=local, pcc=cloud
```

On-device (`system`) works wherever Apple Intelligence is on. Cloud (`pcc`) requires
`fm serve` to be launched from **Terminal.app** — PCC is gated by *process context*, not an
entitlement — after which both report available and any HTTP client can reach them. Both run
*off* your Metal GPU (on the ANE / Apple's servers).

## Benchmarks

[`bench/bench.py`](bench/bench.py) measures TTFT + decode tokens/sec against any tier
(one stdlib tool, no deps):

```bash
python3 bench/bench.py --base-url http://127.0.0.1:8898 --model system      # Apple on-device
python3 bench/bench.py --base-url http://127.0.0.1:8080 --model default      # trailbrake
python3 bench/bench.py --base-url http://127.0.0.1:8100 --model default      # via racecontrol
```

## License

MIT — see [LICENSE](LICENSE).
