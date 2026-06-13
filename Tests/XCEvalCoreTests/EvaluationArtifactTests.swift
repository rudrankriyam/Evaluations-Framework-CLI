import Foundation
import Testing

@testable import XCEvalCore

@Test("Evaluation artifacts expose normalized metadata, metrics, and samples")
func parsesEvaluationArtifact() throws {
    let artifact = try EvaluationArtifact(data: Data(fixture.utf8))

    #expect(artifact.evaluationID == "ExampleEvaluation")
    #expect(artifact.resultID == "RESULT-1")
    #expect(artifact.durationInMilliseconds == 12)
    #expect(artifact.evaluationInfo["Model"]?.stringValue == "Example")
    #expect(artifact.summaries.count == 2)
    let accuracy = try #require(
        artifact.summaries.first { $0.name == "Mean of Accuracy" }
    )
    #expect(accuracy.value == 0.5)
    #expect(artifact.samples.count == 2)

    let first = artifact.samples[0]
    #expect(first.input?["input"]?["prompt"]?.stringValue == "Say hello")
    #expect(first.inputRaw?.contains("Say hello") == true)
    #expect(first.response?["value"]?.stringValue == "hello")
    #expect(first.metrics.first?.name == "Accuracy")
    #expect(first.hasFailure == false)

    let second = artifact.samples[1]
    #expect(second.hasFailure)
    #expect(second.metrics.first?.rationale == "Expected hello.")
}

@Test("Metric comparisons report candidate minus baseline")
func comparesEvaluationArtifacts() throws {
    let baseline = try EvaluationArtifact(data: Data(fixture.utf8))
    let candidateJSON = fixture.replacingOccurrences(
        of: #""value":0.5"#,
        with: #""value":0.75"#
    )
    let candidate = try EvaluationArtifact(data: Data(candidateJSON.utf8))

    let comparison = try #require(
        baseline.comparisons(with: candidate).first {
            $0.name == "Mean of Accuracy"
        }
    )
    #expect(comparison.baseline == 0.5)
    #expect(comparison.candidate == 0.75)
    #expect(comparison.delta == 0.25)
    #expect(comparison.relativeDelta == 0.5)
}

@Test("Metric comparisons preserve groups and repeated summary rows")
func comparesDuplicateSummaryMetrics() throws {
    let baseline = try EvaluationArtifact(
        data: Data(duplicateSummaryBaseline.utf8)
    )
    let candidate = try EvaluationArtifact(
        data: Data(duplicateSummaryCandidate.utf8)
    )

    let comparisons = baseline.comparisons(with: candidate)
    #expect(comparisons.count == 3)
    #expect(comparisons.map(\.group) == ["Quality", "Safety", "Quality"])
    #expect(comparisons.map(\.occurrence) == [1, 1, 2])
    #expect(comparisons.map(\.baseline) == [0.5, 0.7, 0.6])
    #expect(comparisons.map(\.candidate) == [0.8, 0.9, 0.65])

    let encoded = try JSONValue.decode(JSONEncoder().encode(comparisons))
    #expect(encoded.arrayValue?[2]["occurrence"] == .integer(2))
}

@Test("Non-evaluation JSON is rejected")
func rejectsNonEvaluationJSON() {
    #expect(throws: EvaluationArtifactError.self) {
        try EvaluationArtifact(data: Data(#"{"value":1}"#.utf8))
    }
}

@Test("Empty top-level JSON arrays are rejected")
func rejectsEmptyJSONArrays() {
    #expect(throws: EvaluationArtifactLoaderError.self) {
        try EvaluationArtifactLoader.load(data: Data("[]".utf8))
    }
}

@Test("JSON values preserve integer, floating-point, and Boolean types")
func preservesJSONScalarTypes() throws {
    let value = try JSONValue.decode(
        Data(#"{"integer":1,"number":1.5,"bool":true}"#.utf8)
    )

    #expect(value["integer"] == .integer(1))
    #expect(value["number"] == .number(1.5))
    #expect(value["bool"] == .bool(true))
}

@Test("JSONL collections preserve source lines and result identity")
func loadsJSONLines() throws {
    let second = fixture.replacingOccurrences(
        of: #""resultID": "RESULT-1""#,
        with: #""resultID": "RESULT-2""#
    )
    let firstLine = try JSONValue.decode(
        Data(fixture.utf8)
    ).encodedData()
    let secondLine = try JSONValue.decode(
        Data(second.utf8)
    ).encodedData()
    var data = Data()
    data.append(firstLine)
    data.append(0x0A)
    data.append(secondLine)
    data.append(0x0A)
    let artifacts = try EvaluationArtifactLoader.load(
        data: data,
        sourceURL: URL(fileURLWithPath: "/tmp/results.jsonl")
    )

    #expect(artifacts.count == 2)
    #expect(artifacts[0].sourceLine == 1)
    #expect(artifacts[1].sourceLine == 2)
    #expect(artifacts[1].resultID == "RESULT-2")
}

@Test("Metric profiles summarize kinds, failures, rationales, and values")
func profilesMetrics() throws {
    let artifact = try EvaluationArtifact(data: Data(fixture.utf8))
    let accuracy = try #require(
        artifact.metricProfiles.first { $0.name == "Accuracy" }
    )

    #expect(accuracy.sampleCount == 2)
    #expect(accuracy.passCount == 1)
    #expect(accuracy.failCount == 1)
    #expect(accuracy.rationaleCount == 1)
    #expect(accuracy.numericCount == 0)
}

@Test("Dataset extraction supports rich records and Apple's pair shape")
func extractsDataset() throws {
    let artifact = try EvaluationArtifact(data: Data(fixture.utf8))

    #expect(artifact.datasetRecords.count == 2)
    #expect(artifact.datasetRecords[0].prompt == "Say hello")
    #expect(artifact.datasetRecords[0].response == .string("hello"))
    #expect(artifact.datasetPairs[1].response == "goodbye")
}

@Test("Validation remains forward compatible while finding structural errors")
func validatesArtifacts() throws {
    let artifact = try EvaluationArtifact(data: Data(fixture.utf8))
    #expect(artifact.validate().isValid)

    let negativeDuration = fixture.replacingOccurrences(
        of: #""durationInMilliseconds": 12"#,
        with: #""durationInMilliseconds": -1"#
    )
    let invalid = try EvaluationArtifact(
        data: Data(negativeDuration.utf8)
    )
    #expect(!invalid.validate().isValid)
    #expect(
        invalid.validate().issues.contains {
            $0.code == "negative_duration"
        }
    )
}

@Test("Gate rules require explicit direction and resolve aggregate names")
func evaluatesGateRules() throws {
    let artifact = try EvaluationArtifact(data: Data(fixture.utf8))
    let passing = try EvaluationGateRule(
        "Mean of Accuracy>=0.5"
    ).evaluate(in: artifact)
    let failing = try EvaluationGateRule(
        "Mean of Accuracy>0.5"
    ).evaluate(in: artifact)

    #expect(passing.passed)
    #expect(!failing.passed)
    #expect(throws: EvaluationGateError.self) {
        try EvaluationGateRule("Accuracy is good")
    }
}

@Test("Artifact directories recursively load result and JSONL files")
func loadsArtifactDirectories() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("xceval-tests-\(UUID().uuidString)")
    let nested = directory.appendingPathComponent("nested")
    try FileManager.default.createDirectory(
        at: nested,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    try Data(fixture.utf8).write(
        to: directory.appendingPathComponent("one.xcevalresult")
    )
    let second = fixture.replacingOccurrences(
        of: #""resultID": "RESULT-1""#,
        with: #""resultID": "RESULT-2""#
    )
    try Data("\(second)\n".utf8).write(
        to: nested.appendingPathComponent("collection.jsonl")
    )

    let artifacts = try EvaluationArtifactLoader.load(from: directory)
    #expect(
        artifacts.map(\.resultID).compactMap(\.self).sorted() == [
            "RESULT-1",
            "RESULT-2"
        ])
}

@Test("Xcode inspection preserves candidate discovery priority")
func preservesXcodeDiscoveryPriority() {
    let preferred = URL(fileURLWithPath: "/tmp/Z-Priority.app/Contents/Developer")
    let fallback = URL(fileURLWithPath: "/Applications/A-Xcode.app/Contents/Developer")
    let installations = XcodeLocator.inspectCandidates(
        [preferred, fallback]
    ) { candidate in
        XcodeInstallation(
            applicationPath: candidate.deletingLastPathComponent()
                .deletingLastPathComponent().path,
            developerDirectory: candidate.path,
            version: nil,
            build: nil,
            frameworks: [],
            exportsEvaluations: false,
            exportSchemaVersion: nil
        )
    }

    #expect(
        installations.map(\.developerDirectory) == [
            preferred.path,
            fallback.path
        ])
}

@Test("Invalid explicit Xcode paths have a distinct error")
func rejectsInvalidPreferredXcodePath() {
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("missing-xcode-\(UUID().uuidString).app")

    #expect(
        throws: XcodeEnvironmentError.invalidPreferredXcodePath(
            missing.appendingPathComponent("Contents/Developer").path
        )
    ) {
        try XcodeLocator.evaluationCapableInstallation(
            preferredPath: missing.path
        )
    }
}

private let fixture = #"""
    {
      "evaluationID": "ExampleEvaluation",
      "resultID": "RESULT-1",
      "startTime": "2026-06-13T20:00:00Z",
      "endTime": "2026-06-13T20:00:00Z",
      "durationInMilliseconds": 12,
      "evaluationInfo": {"Model": "Example"},
      "reportMetadata": {"ColumnOrdering": ["Input", "Response", "Expected", "Accuracy"]},
      "summary": [
        {
          "Mean of Accuracy":{"group":"Quality","operation":{"metric":"Accuracy","type":"mean"},"value":0.5},
          "Maximum of Latency":{"group":"Latency","operation":{"metric":"Latency","type":"maximum"},"value":2}
        }
      ],
      "results": [
        {
          "Input": "{\"input\":{\"prompt\":\"Say hello\"},\"output\":{\"value\":\"hello\"}}",
          "Response": {"typeName": "String", "value": "hello"},
          "Expected": "hello",
          "Accuracy": {"evaluatorKind": "custom", "kind": "pass", "value": true}
        },
        {
          "Input": "{\"input\":{\"prompt\":\"Say hello\"},\"output\":{\"value\":\"hello\"}}",
          "Response": {"typeName": "String", "value": "goodbye"},
          "Expected": "hello",
          "Accuracy": {
            "evaluatorKind": "custom",
            "kind": "fail",
            "value": false,
            "rationale": "Expected hello."
          }
        }
      ]
    }
    """#

private let duplicateSummaryBaseline = #"""
    {
      "summary": [
        {"Mean Score":{"group":"Quality","operation":{"metric":"Score","type":"mean"},"value":0.5}},
        {"Mean Score":{"group":"Safety","operation":{"metric":"Score","type":"mean"},"value":0.7}},
        {"Mean Score":{"group":"Quality","operation":{"metric":"Score","type":"mean"},"value":0.6}}
      ],
      "results": []
    }
    """#

private let duplicateSummaryCandidate = #"""
    {
      "summary": [
        {"Mean Score":{"group":"Quality","operation":{"metric":"Score","type":"mean"},"value":0.8}},
        {"Mean Score":{"group":"Safety","operation":{"metric":"Score","type":"mean"},"value":0.9}},
        {"Mean Score":{"group":"Quality","operation":{"metric":"Score","type":"mean"},"value":0.65}}
      ],
      "results": []
    }
    """#
