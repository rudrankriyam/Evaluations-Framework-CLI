import Evaluations
import EvaluationsLabSupport
import Foundation
import FoundationModels
import Testing

@Suite("Model samples and tool trajectories")
struct ModelSampleAndToolTests {
    @Test("ModelSample is Codable with trajectory expectations")
    func modelSampleRoundTrip() throws {
        let original = ModelSample<String>(
            prompt: "Use the weather tool.",
            expected: "It is 24 degrees.",
            instructions: "Be concise.",
            expectations: TranscriptFixtures.deterministicExpectation
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ModelSample<String>.self, from: data)

        #expect(decoded.expected == "It is 24 degrees.")
        #expect(decoded.promptDescription.contains("weather"))
        #expect(decoded.instructionsDescription?.contains("concise") == true)
        #expect(decoded.expectations?.ordered.count == 1)
        #expect(decoded.expectations?.disallowed.count == 1)
    }

    @Test("Trajectory matchers are Codable")
    func trajectoryRoundTrip() throws {
        let data = try JSONEncoder().encode(
            TranscriptFixtures.deterministicExpectation
        )
        let decoded = try JSONDecoder().decode(
            TrajectoryExpectation.self,
            from: data
        )

        #expect(decoded.ordered.count == 1)
        #expect(decoded.ordered.first?.arguments.count == 8)
        #expect(decoded.disallowed.count == 1)
    }

    @Test("Transcript conversion preserves all structured lanes")
    func structuredTranscriptConversion() {
        let structured = TranscriptFixtures.structuredTranscript

        #expect(structured.instructionText.contains("Use tools"))
        #expect(structured.prompts == ["What is the weather in Paris?"])
        #expect(structured.toolCalls.count == 1)
        #expect(structured.toolOutputs.count == 1)
        #expect(structured.responses.count == 1)
        #expect(structured.toolCalls.first?.toolName == "weather")
    }

    @Test("ToolCallEvaluator handles deterministic matchers offline")
    func deterministicToolEvaluation() async throws {
        let sample = ModelSample<String>(
            prompt: "Use the weather tool.",
            expected: "It is 24 degrees in Paris.",
            expectations: TranscriptFixtures.deterministicExpectation
        )
        let subject = ModelSubject(
            value: "It is 24 degrees in Paris.",
            transcript: TranscriptFixtures.structuredTranscript
        )
        let allPass = Metric("tool_all_pass")
        let percentage = Metric("tool_percentage")
        let evaluator = ToolCallEvaluator<ModelSample<String>>(
            allPass: allPass,
            percentagePass: percentage
        )

        let metrics = try await evaluator.metrics(subject: subject, input: sample)

        #expect(metrics[allPass]?.value == .passing)
        #expect(metrics[percentage]?.doubleValue == 1)
    }
}
