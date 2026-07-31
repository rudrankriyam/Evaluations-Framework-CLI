import Evaluations
import EvaluationsLabSupport
import Testing

@Suite("Swift Testing integration")
struct SwiftTestingTraitTests {
    @Test(
        "Evaluation trait publishes its scoped result",
        .evaluates(
            OfflineFixtures.evaluation,
            info: ["lane": "swift-testing-trait"]
        )
    )
    func scopedEvaluationContext() {
        let result = EvaluationContext.current.result

        #expect(result.evaluationInfo["lane"] == "swift-testing-trait")
        #expect(result.detailed.rows.count == OfflineFixtures.samples.count)
        #expect(result.aggregateValue(.mean(of: HarnessMetric.exactMatch)) == 0.5)
    }
}
