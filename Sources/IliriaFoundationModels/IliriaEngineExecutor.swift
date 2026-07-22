import Foundation
import FoundationModels

/// The bridge between the Foundation Models framework and an iliria-stack engine.
///
/// The framework hands us a ``LanguageModelExecutorGenerationRequest`` (transcript +
/// generation options); we translate it into an OpenAI-style streaming chat request,
/// POST it to the engine, and forward each token delta back through the channel. This
/// is exactly the role Apple documents for a `LanguageModelExecutor`: "the bridge
/// between the framework types and the system that actually generates the tokens, like
/// a server API or a local inference engine."
@available(macOS 27.0, *)
public struct IliriaEngineExecutor: LanguageModelExecutor {
    public typealias Configuration = IliriaEngineConfiguration
    public typealias Model = IliriaLanguageModel

    let configuration: IliriaEngineConfiguration

    public init(configuration: IliriaEngineConfiguration) throws {
        self.configuration = configuration
    }

    public func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: IliriaLanguageModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        // v1 is text-only. If the framework hands us a request that actually depends on
        // a capability we don't implement yet, fail loudly with a typed error rather than
        // silently ignoring it and returning a plain-text answer that pretends the tools /
        // schema were honored. (These never fire in normal use: `capabilities` advertises
        // neither, so the framework shouldn't attach them — this is the safety net.)
        if !request.enabledToolDefinitions.isEmpty {
            throw IliriaEngineError.unsupportedFeature("tool calling (v1 of this adapter is text-only)")
        }
        if request.schema != nil {
            throw IliriaEngineError.unsupportedFeature("guided / structured generation (v1 of this adapter is text-only)")
        }

        let httpRequest = try makeRequest(from: request)
        let (bytes, response) = try await URLSession.shared.bytes(for: httpRequest)

        guard let http = response as? HTTPURLResponse else {
            throw IliriaEngineError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            var body = ""
            for try await line in bytes.lines {
                body += line
                if body.count > 4096 { break }
            }
            throw IliriaEngineError.httpStatus(code: http.statusCode, body: body)
        }

        var promptTokens = 0
        var completionTokens = 0
        let decoder = JSONDecoder()

        // Server-Sent Events: one `data: {json}` frame per token chunk, `data: [DONE]` to end.
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty { continue }
            if payload == "[DONE]" { break }

            guard let data = payload.data(using: .utf8),
                  let chunk = try? decoder.decode(StreamChunk.self, from: data)
            else { continue }

            if let delta = chunk.choices.first?.delta.content, !delta.isEmpty {
                await channel.send(.response(action: .appendText(delta, tokenCount: 0)))
            }
            if let usage = chunk.usage {
                promptTokens = usage.promptTokens ?? promptTokens
                completionTokens = usage.completionTokens ?? completionTokens
            }
        }

        if promptTokens > 0 || completionTokens > 0 {
            await channel.send(.response(action: .updateUsage(
                input: .init(totalTokenCount: promptTokens, cachedTokenCount: 0),
                output: .init(totalTokenCount: completionTokens, reasoningTokenCount: 0)
            )))
        }
    }

    // MARK: - Framework → OpenAI translation

    private func makeRequest(from request: LanguageModelExecutorGenerationRequest) throws -> URLRequest {
        let body = ChatCompletionsRequest(
            model: configuration.modelName,
            messages: Self.messages(from: request.transcript),
            stream: true,
            temperature: Self.temperature(for: request.generationOptions),
            topP: Self.topP(for: request.generationOptions),
            maxTokens: request.generationOptions.maximumResponseTokens
        )

        var http = URLRequest(url: configuration.baseURL.appendingPathComponent("v1/chat/completions"))
        http.httpMethod = "POST"
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let key = configuration.apiKey {
            http.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        http.httpBody = try JSONEncoder().encode(body)
        return http
    }

    /// Flatten the transcript into OpenAI chat messages. Instructions → system,
    /// prompts → user, prior responses → assistant. Tool-call / tool-output / reasoning
    /// entries are not forwarded to a plain chat-completions endpoint in v1.
    static func messages(from transcript: Transcript) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        for entry in transcript {
            switch entry {
            case .instructions(let instructions):
                messages.append(ChatMessage(role: "system", content: text(of: instructions.segments)))
            case .prompt(let prompt):
                messages.append(ChatMessage(role: "user", content: text(of: prompt.segments)))
            case .response(let response):
                messages.append(ChatMessage(role: "assistant", content: text(of: response.segments)))
            default:
                break
            }
        }
        return messages
    }

    /// Concatenate the plain-text segments of a transcript entry. Structured/attachment
    /// segments are ignored in v1 (text-only bridging).
    static func text(of segments: [Transcript.Segment]) -> String {
        segments.reduce(into: "") { accumulated, segment in
            if case .text(let textSegment) = segment {
                accumulated += textSegment.content
            }
        }
    }

    /// Greedy sampling maps to temperature 0; otherwise pass the requested temperature through.
    static func temperature(for options: GenerationOptions) -> Double? {
        if let kind = options.samplingMode?.kind, case .greedy = kind {
            return 0.0
        }
        return options.temperature
    }

    /// Nucleus sampling maps its probability threshold to `top_p`.
    static func topP(for options: GenerationOptions) -> Double? {
        if let kind = options.samplingMode?.kind, case .nucleus(let threshold, _) = kind {
            return threshold
        }
        return nil
    }
}
