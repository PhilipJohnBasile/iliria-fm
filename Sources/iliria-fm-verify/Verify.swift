import Foundation
import FoundationModels
import IliriaFoundationModels

// End-to-end verification of the provider against a RUNNING OpenAI-compatible engine.
// This is deliberately not a unit test: it drives a real `LanguageModelSession` through
// `IliriaLanguageModel`, so it proves the executor actually works rather than merely compiles.
//
//   racecontrol-fm/fm-serve.sh &                       # cheap: Apple on-device, ANE only
//   swift run iliria-fm-verify                         # defaults to :8898 model "system"
//   swift run iliria-fm-verify http://127.0.0.1:8080 default    # trailbrake

@available(macOS 27.0, *)
@Generable
struct PrimeRequest {
    @Guide(description: "How many prime numbers to return")
    var count: Int
}

@available(macOS 27.0, *)
@Generable
struct Mood {
    @Guide(description: "A single word describing the mood")
    var word: String
}

/// Records whether the framework actually invoked it, which is the point of the test.
final class ToolInvocation: @unchecked Sendable {
    var called = false
    var requestedCount: Int?
}

@available(macOS 27.0, *)
struct ListPrimesTool: Tool {
    typealias Arguments = PrimeRequest

    let name = "list_primes"
    let description = "Returns the first N prime numbers. Use this whenever primes are requested."
    let invocation: ToolInvocation

    func call(arguments: PrimeRequest) async throws -> String {
        invocation.called = true
        invocation.requestedCount = arguments.count
        return "2, 3, 5, 7, 11, 13"
    }
}

@available(macOS 27.0, *)
struct Runner {
    let baseURL: URL
    let modelName: String
    var failures: [String] = []

    mutating func check(_ label: String, _ ok: Bool, _ detail: String = "") {
        print("  \(ok ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
        if !ok { failures.append(label) }
    }

    mutating func run() async -> Int32 {
        let model = IliriaLanguageModel(configuration: IliriaEngineConfiguration(
            baseURL: baseURL, modelName: modelName, apiKey: nil, tier: .local))
        print("iliria-fm-verify → \(baseURL.absoluteString) (model=\(modelName))\n")

        // 1. Plain streamed chat through the executor.
        do {
            let session = LanguageModelSession(model: model)
            let reply = try await session.respond(to: "Reply with exactly the word: OK")
            let text = reply.content.trimmingCharacters(in: .whitespacesAndNewlines)
            check("plain chat", !text.isEmpty, "got \(text.prefix(40))")
        } catch {
            check("plain chat", false, "\(error)")
        }

        // 2. Tool calling: the framework must parse our relayed tool_calls and invoke the tool.
        let invocation = ToolInvocation()
        do {
            let session = LanguageModelSession(
                model: model,
                tools: [ListPrimesTool(invocation: invocation)]
            )
            let reply = try await session.respond(
                to: "Use the list_primes tool to list the first 3 prime numbers.")
            check("tool calling", invocation.called,
                  invocation.called
                    ? "tool invoked with count=\(invocation.requestedCount.map(String.init) ?? "nil")"
                    : "model answered without calling the tool: \(reply.content.prefix(40))")
        } catch {
            check("tool calling", false, "\(error)")
        }

        // 3. Guided generation: a schema must round-trip into structured output.
        do {
            let session = LanguageModelSession(model: model)
            let reply = try await session.respond(
                to: "The weather is sunny and warm. Describe the mood.",
                generating: Mood.self)
            check("guided generation", !reply.content.word.isEmpty, "word=\(reply.content.word)")
        } catch {
            check("guided generation", false, "\(error)")
        }

        print("")
        if failures.isEmpty {
            print("all checks passed")
            return 0
        }
        print("FAILED: \(failures.joined(separator: ", "))")
        return 1
    }
}

@main
enum Verify {
    static func main() async {
        guard #available(macOS 27.0, *) else {
            print("iliria-fm-verify requires macOS 27")
            exit(1)
        }
        let args = CommandLine.arguments.dropFirst()
        let base = args.first ?? "http://127.0.0.1:8898"
        let model = args.dropFirst().first ?? "system"
        guard let url = URL(string: base) else {
            print("bad base URL: \(base)")
            exit(1)
        }
        var runner = Runner(baseURL: url, modelName: model)
        exit(await runner.run())
    }
}
