import Foundation
import FoundationModels

/// The bridge between the Foundation Models framework and an iliria-stack engine.
///
/// The framework hands us a ``LanguageModelExecutorGenerationRequest`` (transcript,
/// generation options, enabled tools, optional output schema); we translate it into an
/// OpenAI-style streaming chat request, POST it to the engine, and forward text deltas and
/// tool-call fragments back through the channel. This is exactly the role Apple documents
/// for a `LanguageModelExecutor`: "the bridge between the framework types and the system
/// that actually generates the tokens, like a server API or a local inference engine."
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
        var toolCalls = ToolCallRelay()
        let decoder = JSONDecoder()

        // Server-Sent Events: one `data: {json}` frame per chunk, `data: [DONE]` to finish.
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty { continue }
            if payload == "[DONE]" { break }

            guard let data = payload.data(using: .utf8),
                  let chunk = try? decoder.decode(StreamChunk.self, from: data)
            else { continue }

            let choice = chunk.choices.first

            if let text = choice?.delta.content, !text.isEmpty {
                await channel.send(.response(action: .appendText(text, tokenCount: 0)))
            }

            for emission in toolCalls.accept(choice?.delta.toolCalls ?? []) {
                await channel.send(.toolCalls(action: .toolCall(
                    id: emission.id,
                    name: emission.name,
                    action: .appendArguments(emission.arguments, tokenCount: 0)
                )))
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
        var body: [String: Any] = [
            "model": configuration.modelName,
            "messages": Self.messages(from: request.transcript).map {
                ["role": $0.role, "content": $0.content]
            },
            "stream": true,
        ]
        if let temperature = Self.temperature(for: request.generationOptions) {
            body["temperature"] = temperature
        }
        if let topP = Self.topP(for: request.generationOptions) {
            body["top_p"] = topP
        }
        if let maxTokens = request.generationOptions.maximumResponseTokens {
            body["max_tokens"] = maxTokens
        }

        // Guided generation. `GenerationSchema` is Codable and its JSON form is already a
        // JSON Schema, so it maps straight onto the OpenAI json_schema response format --
        // no need to re-model arbitrary schema JSON in Swift.
        if let schema = request.schema {
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": [
                    "name": schema.name,
                    "schema": try Self.jsonObject(from: schema),
                ] as [String: Any],
            ] as [String: Any]
        }

        // Tool calling. Each ToolDefinition carries its parameters as a GenerationSchema.
        if !request.enabledToolDefinitions.isEmpty {
            body["tools"] = try request.enabledToolDefinitions.map { definition in
                [
                    "type": "function",
                    "function": [
                        "name": definition.name,
                        "description": definition.description,
                        "parameters": try Self.jsonObject(from: definition.parameters),
                    ] as [String: Any],
                ] as [String: Any]
            }
            if let choice = Self.toolChoice(for: request.generationOptions) {
                body["tool_choice"] = choice
            }
        }

        var http = URLRequest(url: configuration.baseURL.appendingPathComponent("v1/chat/completions"))
        http.httpMethod = "POST"
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let key = configuration.apiKey {
            http.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        http.httpBody = try JSONSerialization.data(withJSONObject: body)
        return http
    }

    /// Round-trip a `GenerationSchema` through its own Codable form into plain JSON objects,
    /// so it can be spliced verbatim into the request body.
    static func jsonObject(from schema: GenerationSchema) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(schema))
    }

    /// Flatten the transcript into OpenAI chat messages. Instructions → system,
    /// prompts → user, prior responses → assistant.
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

    /// Concatenate the plain-text segments of a transcript entry. Structured and attachment
    /// segments (images) are not forwarded — this adapter is text + tools.
    static func text(of segments: [Transcript.Segment]) -> String {
        segments.reduce(into: "") { accumulated, segment in
            if case .text(let textSegment) = segment {
                accumulated += textSegment.content
            }
        }
    }

    /// Greedy sampling maps to temperature 0; otherwise the caller's explicit temperature is
    /// forwarded unchanged.
    ///
    /// This deliberately compares `SamplingMode` **by value** rather than switching on
    /// `SamplingMode.kind`. On the macOS 27 beta the SDK declares `Kind` cases (`.nucleus`,
    /// `.top`) whose symbols are *absent from the installed runtime framework*, so merely
    /// referencing them can fail at dyld load time — verified directly:
    /// `Symbol not found: …GenerationOptions.SamplingMode.Kind.nucleus…`. That would be a
    /// launch crash for any app embedding this package. The Equatable path resolves fine.
    static func temperature(for options: GenerationOptions) -> Double? {
        if options.samplingMode == .greedy {
            return 0.0
        }
        return options.temperature
    }

    /// Nucleus sampling's probability threshold is **not** forwarded as `top_p` yet.
    ///
    /// Recovering the threshold requires `SamplingMode.kind`, whose non-greedy cases are
    /// missing from the macOS 27 beta runtime (see ``temperature(for:)``). Rather than risk a
    /// load-time crash, the threshold is dropped; the caller's explicit `temperature` is
    /// still honored, so sampling is narrowed rather than ignored. Restore this the moment
    /// the runtime ships `Kind` — it is a two-line change plus its test.
    static func topP(for options: GenerationOptions) -> Double? {
        nil
    }

    /// Map the framework's tool-calling mode onto OpenAI's `tool_choice`.
    static func toolChoice(for options: GenerationOptions) -> String? {
        guard let mode = options.toolCallingMode else { return nil }
        if mode == .required { return "required" }
        if mode == .disallowed { return "none" }
        if mode == .allowed { return "auto" }
        return nil
    }
}
