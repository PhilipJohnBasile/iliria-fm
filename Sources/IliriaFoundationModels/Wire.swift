import Foundation

// Minimal OpenAI-compatible chat-completions wire types. trailbrake, iliria, and
// racecontrol all speak this shape on /v1/chat/completions (SSE `data:` frames when
// stream=true), so one adapter covers all three.

struct ChatMessage: Encodable {
    let role: String
    let content: String
}

struct ChatCompletionsRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let stream: Bool
    let temperature: Double?
    let topP: Double?
    let maxTokens: Int?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, temperature
        case topP = "top_p"
        case maxTokens = "max_tokens"
    }
}

struct StreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable { let content: String? }
        let delta: Delta
    }
    struct Usage: Decodable {
        let promptTokens: Int?
        let completionTokens: Int?
        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
        }
    }
    let choices: [Choice]
    let usage: Usage?
}

/// Errors surfaced by the iliria-stack Foundation Models provider.
public enum IliriaEngineError: Error, Sendable {
    /// The engine responded with something other than an HTTP response.
    case invalidResponse
    /// The engine returned a non-2xx status; `body` is a truncated copy of the payload.
    case httpStatus(code: Int, body: String)
    /// The request asked for a capability this adapter version does not implement
    /// (e.g. tool calling or guided/structured generation). Surfaced as an explicit,
    /// typed error rather than silently dropped, so a caller is never misled into
    /// thinking its tools/schema were honored. `feature` names what was requested.
    case unsupportedFeature(_ feature: String)
}
