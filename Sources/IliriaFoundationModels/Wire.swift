import Foundation

// Minimal OpenAI-compatible chat-completions wire types. trailbrake, iliria, and
// racecontrol all speak this shape on /v1/chat/completions (SSE `data:` frames when
// stream=true), so one adapter covers all three.
//
// The request body is assembled as a dictionary rather than an Encodable struct: tool
// parameters and guided-generation schemas arrive as `GenerationSchema`, whose Codable
// form is already JSON Schema, and splicing that in verbatim is simpler and lossless
// compared with re-modelling arbitrary schema JSON in Swift types.

struct ChatMessage {
    let role: String
    let content: String
}

struct StreamChunk: Decodable {
    struct ToolCallDelta: Decodable {
        struct Function: Decodable {
            let name: String?
            let arguments: String?
        }
        /// Present on every fragment; the first fragment of a call also carries `id`/`name`,
        /// later ones only this index plus the next slice of the JSON arguments.
        let index: Int?
        let id: String?
        let function: Function?
    }

    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
            let refusal: String?
            let toolCalls: [ToolCallDelta]?

            enum CodingKeys: String, CodingKey {
                case content, refusal
                case toolCalls = "tool_calls"
            }
        }
        let delta: Delta
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
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

/// Accumulates streamed tool-call fragments and decides what to relay.
///
/// A streamed tool call splits its *identity* (first fragment: `id` + `function.name`) from
/// its *arguments* (later fragments: an index plus the next slice of JSON). Identity is
/// therefore tracked by index so every later fragment can be attributed to the right call --
/// including when several calls stream interleaved.
struct ToolCallRelay {
    struct Emission: Equatable {
        let id: String
        let name: String
        let arguments: String
    }

    private var known: [Int: (id: String, name: String)] = [:]

    mutating func accept(_ fragments: [StreamChunk.ToolCallDelta]) -> [Emission] {
        var emissions: [Emission] = []
        for fragment in fragments {
            let index = fragment.index ?? 0
            let isNewCall = fragment.id != nil && known[index] == nil
            if let id = fragment.id, let name = fragment.function?.name, !name.isEmpty {
                known[index] = (id, name)
            }
            guard let call = known[index] else { continue }
            let arguments = fragment.function?.arguments ?? ""
            // Emit on first sight even with empty arguments, so a zero-argument call is
            // still announced rather than never appearing.
            if isNewCall || !arguments.isEmpty {
                emissions.append(Emission(id: call.id, name: call.name, arguments: arguments))
            }
        }
        return emissions
    }
}

/// Errors surfaced by the iliria-stack Foundation Models provider.
public enum IliriaEngineError: Error, Sendable {
    /// The engine responded with something other than an HTTP response.
    case invalidResponse
    /// The engine returned a non-2xx status; `body` is a truncated copy of the payload.
    case httpStatus(code: Int, body: String)
    /// The request asked for a capability this adapter does not implement. Surfaced as an
    /// explicit, typed error rather than silently dropped, so a caller is never misled into
    /// thinking the feature was honored. `feature` names what was requested.
    case unsupportedFeature(_ feature: String)
}
