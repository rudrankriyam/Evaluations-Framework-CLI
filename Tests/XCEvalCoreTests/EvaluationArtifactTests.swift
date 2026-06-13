import Foundation
import Testing
import XCEvalCore

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

@Test("Non-evaluation JSON is rejected")
func rejectsNonEvaluationJSON() {
    #expect(throws: EvaluationArtifactError.self) {
        try EvaluationArtifact(data: Data(#"{"value":1}"#.utf8))
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
