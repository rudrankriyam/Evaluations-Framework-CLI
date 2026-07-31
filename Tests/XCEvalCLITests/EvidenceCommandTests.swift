import Foundation
import Testing
import XCEvalCore

@testable import XCEvalCLI

@Test("Evidence command parses machine evidence options")
func parsesEvidenceOptions() throws {
    let command = try XCEvalRootCommand.parseAsRoot([
        "evidence",
        "candidate.xcevalresult",
        "--baseline",
        "baseline.xcevalresult",
        "--sample-key",
        "/record/id",
        "--include-structural-differences",
        "--regressions-only",
        "--output",
        "json",
        "--pretty"
    ])
    let evidence = try #require(command as? EvidenceCommand)

    #expect(evidence.path == "candidate.xcevalresult")
    #expect(evidence.baseline == "baseline.xcevalresult")
    #expect(evidence.sampleKey == "/record/id")
    #expect(evidence.includeStructuralDifferences)
    #expect(evidence.regressionsOnly)
    #expect(evidence.output == .json)
    #expect(evidence.pretty)
}

@Test("Evidence payload contains deterministic failures and deltas")
func buildsEvidencePayload() throws {
    let baseline = try evidenceArtifact(
        resultID: "BASELINE",
        accuracy: 1,
        results: #"""
            {
              "Input":{"record":{"id":"regressed","prompt":"Regress me"}},
              "Response":{"value":"right"},
              "Expected":"right",
              "Accuracy":{"kind":"pass","value":true}
            },
            {
              "Input":{"record":{"id":"existing","prompt":"Already failing"}},
              "Response":{"value":"wrong"},
              "Expected":"right",
              "Accuracy":{
                "kind":"fail",
                "value":false,
                "rationale":"Expected right."
              }
            },
            {
              "Input":{"record":{"id":"structural","prompt":"Compare structure"}},
              "Response":{"value":{"tags":["a"]}},
              "Expected":{"tags":["a","b"]}
            }
            """#
    )
    let candidate = try evidenceArtifact(
        resultID: "CANDIDATE",
        accuracy: 0.5,
        results: #"""
            {
              "Input":{"record":{"id":"regressed","prompt":"Regress me"}},
              "Response":{"value":"wrong"},
              "Expected":"right",
              "Accuracy":{
                "kind":"fail",
                "value":false,
                "rationale":"Expected right."
              }
            },
            {
              "Input":{"record":{"id":"existing","prompt":"Already failing"}},
              "Response":{"value":"wrong"},
              "Expected":"right",
              "Accuracy":{
                "kind":"fail",
                "value":false,
                "rationale":"Expected right."
              }
            },
            {
              "Input":{"record":{"id":"structural","prompt":"Compare structure"}},
              "Response":{"value":{"tags":["a"]}},
              "Expected":{"tags":["a","b"]}
            },
            {
              "Input":{"record":{"id":"added","prompt":"New failure"}},
              "Response":{"value":"bad"},
              "Expected":"good",
              "Accuracy":{"kind":"fail","value":false}
            }
            """#
    )
    let strategy = EvaluationSampleKeyStrategy.jsonPointer("/record/id")
    let payload = makeEvidencePayload(
        artifact: candidate,
        baseline: baseline,
        keyStrategy: strategy,
        includeStructuralDifferences: true,
        regressionsOnly: false
    )

    #expect(payload.command == "evidence")
    #expect(payload.artifact.resultID == "CANDIDATE")
    #expect(payload.baseline?.resultID == "BASELINE")
    #expect(payload.sampleKeyStrategy == strategy)
    #expect(payload.failingSamples.map(\.index) == [0, 1, 2, 3])
    #expect(payload.failingSamples[0].prompt == "Regress me")
    #expect(
        payload.failingSamples[0].metrics.first?.rationale
            == "Expected right."
    )
    #expect(
        payload.failingSamples[2].structuralDifferences.first?.kind
            == .arrayCountMismatch
    )
    #expect(payload.aggregateDeltas.count == 1)
    #expect(payload.aggregateDeltas.first?.delta == -0.5)
    #expect(
        payload.sampleDeltas.map(\.classification) == [
            .regressed,
            .added
        ]
    )

    let encoded = try JSONEncoder().encode(payload)
    let json = try #require(
        try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    let samples = try #require(json["failingSamples"] as? [[String: Any]])
    #expect(samples.first?["inputRaw"] == nil)
}

@Test("Regression-only evidence removes pre-existing failures")
func filtersEvidenceToRegressions() throws {
    let baseline = try evidenceArtifact(
        resultID: "BASELINE",
        accuracy: 1,
        results: #"""
            {
              "Input":{"record":{"id":"regressed"}},
              "Response":{"value":"right"},
              "Expected":"right",
              "Accuracy":{"kind":"pass","value":true}
            },
            {
              "Input":{"record":{"id":"existing"}},
              "Accuracy":{"kind":"fail","value":false}
            }
            """#
    )
    let candidate = try evidenceArtifact(
        resultID: "CANDIDATE",
        accuracy: 0.5,
        results: #"""
            {
              "Input":{"record":{"id":"regressed"}},
              "Response":{"value":"wrong"},
              "Expected":"right",
              "Accuracy":{"kind":"fail","value":false}
            },
            {
              "Input":{"record":{"id":"existing"}},
              "Accuracy":{"kind":"fail","value":false}
            }
            """#
    )
    let payload = makeEvidencePayload(
        artifact: candidate,
        baseline: baseline,
        keyStrategy: .jsonPointer("/record/id"),
        includeStructuralDifferences: false,
        regressionsOnly: true
    )

    #expect(payload.failingSamples.map(\.index) == [0])
    #expect(payload.sampleDeltas.map(\.classification) == [.regressed])
    #expect(payload.aggregateDeltas.count == 1)
}

private func evidenceArtifact(
    resultID: String,
    accuracy: Double,
    results: String
) throws -> EvaluationArtifact {
    try EvaluationArtifact(
        data: Data(
            """
            {
              "evaluationID": "Evidence",
              "resultID": "\(resultID)",
              "summary": [
                {
                  "Mean of Accuracy": {
                    "operation": {
                      "metric": "Accuracy",
                      "type": "mean"
                    },
                    "value": \(accuracy)
                  }
                }
              ],
              "results": [
                \(results)
              ]
            }
            """.utf8
        )
    )
}
