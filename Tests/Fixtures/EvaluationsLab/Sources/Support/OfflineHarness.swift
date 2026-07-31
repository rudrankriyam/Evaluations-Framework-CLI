import Evaluations
import Foundation

public struct OfflineRunSummary: Codable, Sendable {
    public let evaluationID: String
    public let resultID: UUID
    public let jsonPath: String
    public let jsonLinesPath: String
    public let jsonLoadStatus: String
    public let jsonLinesLoadStatus: String
    public let loadedJSONLinesResultCount: Int?
    public let exactMatchMean: Double
    public let duration: TimeInterval

    enum CodingKeys: String, CodingKey {
        case evaluationID
        case resultID
        case jsonPath = "JSONPath"
        case jsonLinesPath = "JSONLinesPath"
        case jsonLoadStatus = "JSONLoadStatus"
        case jsonLinesLoadStatus = "JSONLinesLoadStatus"
        case loadedJSONLinesResultCount
        case exactMatchMean
        case duration
    }
}

public enum OfflineHarness {
    public static func run(in outputDirectory: URL) async throws -> OfflineRunSummary {
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        var result = try await OfflineFixtures.evaluation.run(
            info: [
                "fixture": "EvaluationsLab",
                "lane": "deterministic-offline"
            ]
        )
        result.reportMetadata["producer"] = "EvaluationsLabCLI"

        let jsonURL = try result.saveJSON(to: outputDirectory)
        let loadedJSON = try EvaluationResult.loadJSON(from: jsonURL)
        guard loadedJSON.resultID == result.resultID else {
            throw OfflineHarnessError.jsonResultIdentityMismatch
        }

        let jsonLinesURL = outputDirectory.appending(
            path: "evaluation-results.jsonl",
            directoryHint: .notDirectory
        )
        try [result, result].saveJSONLines(to: jsonLinesURL)

        let loadedLines = try await EvaluationResult.loadJSONLines(
            from: jsonLinesURL
        )
        guard loadedLines.map(\.resultID) == [result.resultID, result.resultID] else {
            throw OfflineHarnessError.jsonLinesResultIdentityMismatch
        }

        return OfflineRunSummary(
            evaluationID: result.evaluationID,
            resultID: result.resultID,
            jsonPath: jsonURL.path,
            jsonLinesPath: jsonLinesURL.path,
            jsonLoadStatus: "loaded",
            jsonLinesLoadStatus: "loaded",
            loadedJSONLinesResultCount: loadedLines.count,
            exactMatchMean: result.aggregateValue(.mean(of: HarnessMetric.exactMatch)),
            duration: result.duration
        )
    }
}

private enum OfflineHarnessError: Error {
    case jsonResultIdentityMismatch
    case jsonLinesResultIdentityMismatch
}
