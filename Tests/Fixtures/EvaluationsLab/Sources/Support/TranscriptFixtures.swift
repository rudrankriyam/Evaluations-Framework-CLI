import Evaluations
import FoundationModels

public enum TranscriptFixtures {
    public static var deterministicExpectation: TrajectoryExpectation {
        let weather = ToolExpectation(
            "weather",
            arguments: [
                .exact(argumentName: "city", value: "Paris"),
                .keyOnly(argumentName: "city"),
                .oneOf(argumentName: "count", allowedValues: [3, 4]),
                .range(argumentName: "temperature", minimum: 20, maximum: 30),
                .pattern(argumentName: "city", regex: "^Par"),
                .contains(argumentName: "city", substring: "ari"),
                .hasPrefix(argumentName: "city", prefix: "Par"),
                .hasSuffix(argumentName: "city", suffix: "ris")
            ]
        )

        return TrajectoryExpectation(
            ordered: [weather],
            unordered: [],
            disallowed: [ToolExpectation("delete_account")]
        )
    }

    public static var naturalLanguageExpectation: TrajectoryExpectation {
        TrajectoryExpectation(
            expected: "weather",
            arguments: [
                .naturalLanguage(
                    argumentName: "city",
                    criteria: "A city in France"
                )
            ]
        )
    }

    public static var transcript: Transcript {
        let instructionSegment = Transcript.TextSegment(
            id: "instruction-text",
            content: "Use tools when needed."
        )
        let promptSegment = Transcript.TextSegment(
            id: "prompt-text",
            content: "What is the weather in Paris?"
        )
        let responseSegment = Transcript.TextSegment(
            id: "response-text",
            content: "It is 24 degrees in Paris."
        )
        let outputSegment = Transcript.TextSegment(
            id: "output-text",
            content: "24 degrees"
        )
        let arguments = GeneratedContent(
            properties: [
                "city": "Paris",
                "count": 3,
                "temperature": 24.0,
                "active": true
            ]
        )
        let call = Transcript.ToolCall(
            id: "weather-call",
            toolName: "weather",
            arguments: arguments
        )
        let output = Transcript.ToolOutput(
            id: "weather-call",
            toolName: "weather",
            segments: [.text(outputSegment)]
        )

        return Transcript(
            entries: [
                .instructions(
                    Transcript.Instructions(
                        id: "instructions",
                        segments: [.text(instructionSegment)],
                        toolDefinitions: []
                    )
                ),
                .prompt(
                    Transcript.Prompt(
                        id: "prompt",
                        segments: [.text(promptSegment)]
                    )
                ),
                .toolCalls(
                    Transcript.ToolCalls(
                        id: "tool-calls",
                        [call]
                    )
                ),
                .toolOutput(output),
                .response(
                    Transcript.Response(
                        id: "response",
                        segments: [.text(responseSegment)]
                    )
                )
            ]
        )
    }

    public static var structuredTranscript: StructuredTranscript {
        transcript.structuredTranscript
    }
}
