import Foundation
import FoundationModels

/// Which tier of the iliria stack a model instance targets. Informational (it is
/// attached to request metadata); the actual endpoint is decided by `baseURL`.
public enum IliriaTier: String, Hashable, Sendable {
    /// Fast on-device engine (trailbrake, Metal) — the analogue of `SystemLanguageModel`.
    case local
    /// Deep-reasoning engine (iliria, GLM-5.2) — the "bigger model" analogue of
    /// `PrivateCloudComputeLanguageModel`, served locally over NVMe expert-streaming.
    case deep
    /// Let the racecontrol router pick local vs. deep per request.
    case routed
}

/// Everything an ``IliriaEngineExecutor`` needs to reach one engine.
@available(macOS 27.0, *)
public struct IliriaEngineConfiguration: Hashable, Sendable {
    /// Base URL of the engine's OpenAI-compatible server, e.g. `http://127.0.0.1:8080`.
    public var baseURL: URL
    /// The `model` field sent in the request body (engines serve a single loaded model,
    /// so this is mostly a label; racecontrol uses it to select a tier when `tier == .routed`).
    public var modelName: String
    /// Optional bearer token, if the engine/router is configured to require one.
    public var apiKey: String?
    /// Which tier this configuration targets.
    public var tier: IliriaTier

    public init(baseURL: URL, modelName: String, apiKey: String? = nil, tier: IliriaTier) {
        self.baseURL = baseURL
        self.modelName = modelName
        self.apiKey = apiKey
        self.tier = tier
    }
}

/// A Foundation Models ``LanguageModel`` backed by one of the iliria-stack engines
/// over its OpenAI-compatible HTTP endpoint.
///
/// Use it exactly like Apple's `SystemLanguageModel`:
/// ```swift
/// let session = LanguageModelSession(model: IliriaLanguageModel.local())
/// let reply = try await session.respond(to: "Summarize this in one line: …")
/// ```
///
/// ``local()`` is the fast tier, ``deep()`` is the deep-reasoning tier, and ``routed()``
/// hands the choice to racecontrol. Every factory takes a `baseURL`: the defaults are
/// loopback, but nothing here assumes localhost — point any of them at a remote host
/// running the same OpenAI-compatible endpoint.
@available(macOS 27.0, *)
public struct IliriaLanguageModel: LanguageModel {
    public typealias Executor = IliriaEngineExecutor

    public var executorConfiguration: IliriaEngineConfiguration

    public init(configuration: IliriaEngineConfiguration) {
        self.executorConfiguration = configuration
    }

    /// Declared to match exactly what the executor implements: streamed text, tool calling
    /// (transcript tool definitions → OpenAI `tools`, with streamed `tool_calls` fragments
    /// relayed back), and guided generation (`GenerationSchema` → the `json_schema` response
    /// format). `.vision` is deliberately absent — image/attachment segments are not
    /// forwarded.
    public var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities([.toolCalling, .guidedGeneration])
    }

    // MARK: - Local + cloud + routed factories

    /// The fast on-device tier (trailbrake). Defaults to `trailbrake serve --port 8080`.
    public static func local(
        baseURL: URL = URL(string: "http://127.0.0.1:8080")!,
        model: String = "trailbrake",
        apiKey: String? = nil
    ) -> IliriaLanguageModel {
        IliriaLanguageModel(configuration: IliriaEngineConfiguration(
            baseURL: baseURL, modelName: model, apiKey: apiKey, tier: .local))
    }

    /// The deep-reasoning tier (iliria, GLM-5.2). Defaults to a local `ili serve` on port
    /// 8000 — but pass any `baseURL` to reach an iliria you host elsewhere.
    ///
    /// Note: this is always *your* deployment, local or remote. Apple's Private Cloud
    /// Compute runs only Apple's own models and cannot host a third-party model such as
    /// GLM-5.2; that is precisely why the framework exposes `LanguageModel` for
    /// bring-your-own-provider instead.
    public static func deep(
        baseURL: URL = URL(string: "http://127.0.0.1:8000")!,
        model: String = "iliria",
        apiKey: String? = nil
    ) -> IliriaLanguageModel {
        IliriaLanguageModel(configuration: IliriaEngineConfiguration(
            baseURL: baseURL, modelName: model, apiKey: apiKey, tier: .deep))
    }

    /// Former name for ``deep(baseURL:model:apiKey:)``. Renamed because "cloud" implied this
    /// tier was cloud-hosted (it defaults to loopback) and invited confusion with Apple's
    /// Private Cloud Compute, which cannot run third-party models.
    @available(*, deprecated, renamed: "deep(baseURL:model:apiKey:)")
    public static func cloud(
        baseURL: URL = URL(string: "http://127.0.0.1:8000")!,
        model: String = "iliria",
        apiKey: String? = nil
    ) -> IliriaLanguageModel {
        deep(baseURL: baseURL, model: model, apiKey: apiKey)
    }

    /// Hand the local/deep decision to the racecontrol router. Defaults to port 8100.
    public static func routed(
        baseURL: URL = URL(string: "http://127.0.0.1:8100")!,
        model: String = "auto",
        apiKey: String? = nil
    ) -> IliriaLanguageModel {
        IliriaLanguageModel(configuration: IliriaEngineConfiguration(
            baseURL: baseURL, modelName: model, apiKey: apiKey, tier: .routed))
    }
}
