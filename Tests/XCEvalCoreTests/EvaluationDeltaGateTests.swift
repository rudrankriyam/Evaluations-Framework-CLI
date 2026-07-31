import Foundation
import Testing

@testable import XCEvalCore

@Test("Delta gates compare candidate minus baseline explicitly")
func deltaGate() throws {
    let baseline = try EvaluationArtifact(
        data: Data(
            """
            {
              "results": [],
              "summary": [
                {"Mean of Accuracy": {"value": 0.8}}
              ]
            }
            """.utf8
        )
    )
    let candidate = try EvaluationArtifact(
        data: Data(
            """
            {
              "results": [],
              "summary": [
                {"Mean of Accuracy": {"value": 0.9}}
              ]
            }
            """.utf8
        )
    )

    let result = try EvaluationDeltaGateRule(
        "Mean of Accuracy>=0.09"
    ).evaluate(baseline: baseline, candidate: candidate)

    #expect(result.passed)
    #expect(EvaluationGateRule.approximatelyEqual(result.delta, 0.1))
    #expect(result.baseline == 0.8)
    #expect(result.candidate == 0.9)
}
