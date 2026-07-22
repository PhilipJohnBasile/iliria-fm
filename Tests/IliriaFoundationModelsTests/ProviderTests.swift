import XCTest
import FoundationModels
@testable import IliriaFoundationModels

private func fragment(
    index: Int? = 0,
    id: String? = nil,
    name: String? = nil,
    arguments: String? = nil
) -> StreamChunk.ToolCallDelta {
    StreamChunk.ToolCallDelta(
        index: index,
        id: id,
        function: .init(name: name, arguments: arguments)
    )
}

/// The trickiest logic in the provider: a streamed tool call arrives as an identity fragment
/// followed by argument slices that carry only an index, so attribution is easy to get wrong
/// and would fail silently (a tool invoked with truncated or misattributed arguments).
final class ToolCallRelayTests: XCTestCase {

    func testIdentityFromFirstFragmentIsAppliedToLaterArgumentSlices() {
        var relay = ToolCallRelay()
        var emissions: [ToolCallRelay.Emission] = []
        emissions += relay.accept([fragment(id: "call_1", name: "list_primes", arguments: "")])
        emissions += relay.accept([fragment(arguments: "{\"count\":")])
        emissions += relay.accept([fragment(arguments: "3}")])

        XCTAssertEqual(emissions.map(\.id), ["call_1", "call_1", "call_1"])
        XCTAssertEqual(emissions.map(\.name), ["list_primes", "list_primes", "list_primes"])
        XCTAssertEqual(
            emissions.map(\.arguments).joined(),
            "{\"count\":3}",
            "argument slices must concatenate back into the original JSON"
        )
    }

    func testInterleavedCallsAreAttributedByIndex() {
        var relay = ToolCallRelay()
        _ = relay.accept([
            fragment(index: 0, id: "call_a", name: "alpha", arguments: ""),
            fragment(index: 1, id: "call_b", name: "beta", arguments: ""),
        ])
        let emissions = relay.accept([
            fragment(index: 1, arguments: "{\"b\":1}"),
            fragment(index: 0, arguments: "{\"a\":2}"),
        ])

        XCTAssertEqual(emissions.count, 2)
        XCTAssertEqual(emissions[0].name, "beta")
        XCTAssertEqual(emissions[0].arguments, "{\"b\":1}")
        XCTAssertEqual(emissions[1].name, "alpha")
        XCTAssertEqual(emissions[1].arguments, "{\"a\":2}")
    }

    func testZeroArgumentCallIsStillAnnouncedOnce() {
        var relay = ToolCallRelay()
        let first = relay.accept([fragment(id: "call_1", name: "now", arguments: nil)])
        let second = relay.accept([fragment(arguments: nil)])

        XCTAssertEqual(first.count, 1, "a call with no arguments must still be announced")
        XCTAssertEqual(first.first?.arguments, "")
        XCTAssertTrue(second.isEmpty, "empty follow-up fragments must not re-emit")
    }

    func testFragmentWithNoKnownIdentityIsDropped() {
        var relay = ToolCallRelay()
        XCTAssertTrue(
            relay.accept([fragment(index: 7, arguments: "{\"x\":1}")]).isEmpty,
            "arguments for a call we never saw an id/name for cannot be attributed"
        )
    }

    func testDecodesOpenAIStreamingToolCallFrame() throws {
        let json = """
        {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function",
        "function":{"name":"list_primes","arguments":"{\\"count\\":3}"}}]},"finish_reason":null}]}
        """
        let chunk = try JSONDecoder().decode(StreamChunk.self, from: Data(json.utf8))
        let call = try XCTUnwrap(chunk.choices.first?.delta.toolCalls?.first)
        XCTAssertEqual(call.id, "call_1")
        XCTAssertEqual(call.function?.name, "list_primes")
        XCTAssertEqual(call.function?.arguments, "{\"count\":3}")
    }

    func testDecodesFinishReasonAndRefusal() throws {
        let json = #"{"choices":[{"delta":{"refusal":"no"},"finish_reason":"tool_calls"}]}"#
        let chunk = try JSONDecoder().decode(StreamChunk.self, from: Data(json.utf8))
        XCTAssertEqual(chunk.choices.first?.finishReason, "tool_calls")
        XCTAssertEqual(chunk.choices.first?.delta.refusal, "no")
    }
}

@available(macOS 27.0, *)
final class TranscriptMappingTests: XCTestCase {

    func testTranscriptFlattensToChatRoles() {
        let transcript = Transcript(entries: [
            .instructions(.init(segments: [.text(.init(content: "Be terse."))], toolDefinitions: [])),
            .prompt(.init(segments: [.text(.init(content: "Hello"))])),
            .response(.init(segments: [.text(.init(content: "Hi"))])),
        ])
        let messages = IliriaEngineExecutor.messages(from: transcript)

        XCTAssertEqual(messages.map(\.role), ["system", "user", "assistant"])
        XCTAssertEqual(messages.map(\.content), ["Be terse.", "Hello", "Hi"])
    }

    func testMultipleTextSegmentsConcatenate() {
        let segments: [Transcript.Segment] = [
            .text(.init(content: "one ")),
            .text(.init(content: "two")),
        ]
        XCTAssertEqual(IliriaEngineExecutor.text(of: segments), "one two")
    }
}

@available(macOS 27.0, *)
final class GenerationOptionMappingTests: XCTestCase {

    func testGreedySamplingBecomesTemperatureZero() {
        let options = GenerationOptions(samplingMode: .greedy)
        XCTAssertEqual(IliriaEngineExecutor.temperature(for: options), 0.0)
    }

    func testExplicitTemperaturePassesThrough() {
        let options = GenerationOptions(temperature: 0.4)
        XCTAssertEqual(IliriaEngineExecutor.temperature(for: options), 0.4)
    }

    func testNonGreedySamplingFallsThroughToExplicitTemperature() {
        let options = GenerationOptions(samplingMode: .random(probabilityThreshold: 0.9),
                                        temperature: 0.7)
        XCTAssertEqual(IliriaEngineExecutor.temperature(for: options), 0.7)
    }

    /// Regression guard for a beta SDK/runtime mismatch: `temperature`/`topP` must NOT switch
    /// on `SamplingMode.kind`. The macOS 27 SDK declares `Kind` cases (`.nucleus`, `.top`)
    /// whose symbols are absent from the installed runtime framework, so referencing them can
    /// fail at dyld load time — a launch crash for any embedding app. Value comparison is safe.
    func testNucleusThresholdIsNotForwardedOnThisRuntime() {
        let options = GenerationOptions(samplingMode: .random(probabilityThreshold: 0.9))
        XCTAssertNil(
            IliriaEngineExecutor.topP(for: options),
            "documented gap: recovering the threshold needs SamplingMode.kind, which the "
                + "beta runtime does not ship"
        )
    }

    func testToolCallingModeMapsToToolChoice() {
        XCTAssertEqual(
            IliriaEngineExecutor.toolChoice(for: GenerationOptions(toolCallingMode: .required)),
            "required"
        )
        XCTAssertEqual(
            IliriaEngineExecutor.toolChoice(for: GenerationOptions(toolCallingMode: .disallowed)),
            "none"
        )
        XCTAssertNil(
            IliriaEngineExecutor.toolChoice(for: GenerationOptions()),
            "no mode requested means no tool_choice is sent at all"
        )
    }
}
