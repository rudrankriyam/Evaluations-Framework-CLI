import Evaluations
import EvaluationsLabSupport
import Foundation
import TabularData
import Testing

@Suite("Deterministic offline evaluation")
struct OfflineEvaluationTests {
    @Test("Evaluation.run produces custom metrics and aggregates")
    func directRunAndAggregation() async throws {
        let result = try await OfflineFixtures.evaluation.run(
            info: ["lane": "direct-run"]
        )

        #expect(result.evaluationInfo["lane"] == "direct-run")
        #expect(result.detailed.rows.count == OfflineFixtures.samples.count)
        #expect(result[metric: HarnessMetric.exactMatch].count == OfflineFixtures.samples.count)
        #expect(result.aggregateValue(.mean(of: HarnessMetric.exactMatch)) == 0.5)
        #expect(result.aggregateValue(.maximum(of: HarnessMetric.lengthDelta)) == 1)
        #expect(result.groupedSummary.contains("quality"))
    }

    @Test("EvaluationResult persists as JSON and JSON Lines")
    func resultPersistence() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "EvaluationsLabPersistence-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        var result = try await OfflineFixtures.evaluation.run()
        result.reportMetadata["lane"] = "persistence"

        let jsonURL = try result.saveJSON(to: directory)
        let jsonData = try Data(contentsOf: jsonURL)
        #expect(try JSONSerialization.jsonObject(with: jsonData) is [String: Any])

        let loaded = try EvaluationResult.loadJSON(from: jsonURL)
        #expect(loaded.resultID == result.resultID)
        #expect(loaded.evaluationID == result.evaluationID)
        #expect(loaded.detailed.rows.count == result.detailed.rows.count)

        let linesURL = directory.appending(
            path: "results.jsonl",
            directoryHint: .notDirectory
        )
        let savedLinesURL = try [result, result].saveJSONLines(to: linesURL)
        #expect(savedLinesURL == linesURL)

        let linesData = try Data(contentsOf: linesURL)
        #expect(!linesData.isEmpty)

        let loadedLines = try await EvaluationResult.loadJSONLines(from: linesURL)
        #expect(loadedLines.count == 2)
        #expect(loadedLines.map(\.resultID) == [result.resultID, result.resultID])

        let summaryFrame = try result.jsonRepresentableDataFrame(of: .summary)
        let detailedFrame = try result.jsonRepresentableDataFrame(of: .detailed)
        #expect(summaryFrame.columns.count > 0)
        #expect(detailedFrame.rows.count == OfflineFixtures.samples.count)
    }

    @Test("Array, JSON, and Stream loaders yield the same samples")
    func loaderParity() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "EvaluationsLabLoaders-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let jsonURL = directory.appending(
            path: "samples.json",
            directoryHint: .notDirectory
        )
        try OfflineFixtures.writeSamplesJSON(to: jsonURL)

        let arraySamples = try await OfflineFixtures.collect(OfflineFixtures.arrayLoader)
        let jsonSamples = try await OfflineFixtures.collect(
            JSONLoader<TextSample>(url: jsonURL)
        )
        let streamSamples = try await OfflineFixtures.collect(
            StreamLoader(stream: OfflineFixtures.throwingStream())
        )

        #expect(arraySamples == OfflineFixtures.samples)
        #expect(jsonSamples == OfflineFixtures.samples)
        #expect(streamSamples == OfflineFixtures.samples)
    }
}

extension EvaluationResult {
    fileprivate subscript(metric metric: Metric) -> TabularData.Column<Metric> {
        detailed[metric: metric]
    }
}
