import Evaluations
import EvaluationsLabSupport
import Foundation
import Testing

@Suite("Focused release verification")
struct HarnessVerificationTests {
    @Test("Offline evaluation and aggregation")
    func offlineEvaluation() async throws {
        let result = try await OfflineFixtures.evaluation.run(
            info: ["lane": "release-verification"]
        )

        #expect(result.evaluationInfo["lane"] == "release-verification")
        #expect(result.detailed.rows.count == OfflineFixtures.samples.count)
        #expect(result.aggregateValue(.mean(of: HarnessMetric.exactMatch)) == 0.5)
    }

    @Test("JSON and JSON Lines round trips")
    func persistenceRoundTrips() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "EvaluationsLabVerification-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let result = try await OfflineFixtures.evaluation.run()
        let jsonURL = try result.saveJSON(to: directory)
        let loadedJSON = try EvaluationResult.loadJSON(from: jsonURL)
        #expect(loadedJSON.resultID == result.resultID)

        let jsonLinesURL = directory.appending(path: "results.jsonl")
        try [result, result].saveJSONLines(to: jsonLinesURL)
        let loadedJSONLines = try await EvaluationResult.loadJSONLines(
            from: jsonLinesURL
        )
        #expect(loadedJSONLines.map(\.resultID) == [result.resultID, result.resultID])
    }

    @Test("Deterministic ToolCallEvaluator")
    func deterministicToolCallEvaluator() async throws {
        let allPass = Metric("verification_tool_all_pass")
        let percentagePass = Metric("verification_tool_percentage")
        let evaluator = ToolCallEvaluator<ModelSample<String>>(
            allPass: allPass,
            percentagePass: percentagePass
        )
        let sample = ModelSample<String>(
            prompt: "Use the weather tool.",
            expected: "It is 24 degrees in Paris.",
            expectations: TranscriptFixtures.deterministicExpectation
        )
        let subject = ModelSubject(
            value: "It is 24 degrees in Paris.",
            transcript: TranscriptFixtures.structuredTranscript
        )

        let metrics = try await evaluator.metrics(subject: subject, input: sample)

        #expect(metrics[allPass]?.value == .passing)
        #expect(metrics[percentagePass]?.doubleValue == 1)
    }
}
