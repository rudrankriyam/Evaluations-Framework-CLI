import Evaluations
import Foundation
import FoundationModels
import Testing

private let advancedJudgeRuntimeEnabled =
    ProcessInfo.processInfo.environment["EVALUATIONS_LAB_RUN_MODEL_TESTS"] == "1"

@available(macOS 27.0, *)
struct AdvancedJudgeRuntimeCase: Sendable {
    let split: String
    let sample: ModelSample<String>
    let candidate: String
}

@available(macOS 27.0, *)
enum AdvancedJudgeRuntimeFixtures {
    static let cases: [AdvancedJudgeRuntimeCase] = [
        AdvancedJudgeRuntimeCase(
            split: "calibration",
            sample: ModelSample(
                prompt: "Give a concise definition of photosynthesis.",
                expected:
                    "Photosynthesis converts light energy into chemical energy in plants."
            ),
            candidate:
                "Photosynthesis lets plants use light to make chemical energy."
        ),
        AdvancedJudgeRuntimeCase(
            split: "calibration",
            sample: ModelSample(
                prompt: "State the result of 8 multiplied by 7.",
                expected: "56"
            ),
            candidate: "The result is 56."
        ),
        AdvancedJudgeRuntimeCase(
            split: "holdout",
            sample: ModelSample(
                prompt: "Explain why seasons occur in one sentence.",
                expected:
                    "Seasons occur because Earth's axis is tilted as it orbits the Sun."
            ),
            candidate:
                "Earth's axial tilt changes the sunlight each hemisphere receives during its orbit."
        ),
        AdvancedJudgeRuntimeCase(
            split: "holdout",
            sample: ModelSample(
                prompt: "Name the capital of Japan.",
                expected: "Tokyo"
            ),
            candidate: "Tokyo is the capital of Japan."
        )
    ]
}

@available(macOS 27.0, *)
private func checkJudgeMetrics(
    _ metrics: [Metric],
    requestedDimensionCount: Int
) {
    let metricNames = metrics.map(\.name)
    print("Model judge returned metrics: \(metricNames)")

    #expect(!metrics.isEmpty)
    #expect(metrics.count <= requestedDimensionCount)
    #expect(Set(metricNames).count == metricNames.count)
    for metric in metrics {
        #expect(metric.doubleValue != nil)
        #expect(metric.rationale?.isEmpty == false)
    }
}

@available(macOS 27.0, *)
@Test(
    "Pointwise and pairwise judge loops are opt in",
    .enabled(if: advancedJudgeRuntimeEnabled)
)
func advancedPointwiseAndPairwiseJudgeRuntime() async throws {
    let model = SystemLanguageModel()
    #expect(
        model.isAvailable,
        "The opt-in judge lane requires an available system model."
    )
    guard model.isAvailable else {
        return
    }

    let pointwise = ModelJudgeEvaluator<ModelSample<String>>(
        judge: model,
        dimensions: [
            AdvancedModelJudgeCoverage.relevance,
            AdvancedModelJudgeCoverage.safety,
            AdvancedModelJudgeCoverage.clarity
        ],
        scoringMode: .continuous,
        prompt: AdvancedModelJudgeCoverage.pointwisePrompt
    )
    let pairwise = ModelJudgeEvaluator<ModelSample<String>>.pairwise(
        "Candidate versus Baseline",
        scale: .custom(AdvancedCoverageScoreLevel.self),
        judge: model,
        scoringMode: .continuous,
        evaluationTarget: { response in response }
    )

    for runtimeCase in AdvancedJudgeRuntimeFixtures.cases {
        _ = try await pointwise.judgePrompt(
            for: runtimeCase.sample,
            output: runtimeCase.candidate
        )

        let candidateMetrics = try await pointwise.metrics(
            subject: ModelSubject(value: runtimeCase.candidate),
            input: runtimeCase.sample
        )
        checkJudgeMetrics(
            candidateMetrics,
            requestedDimensionCount: 3
        )

        guard runtimeCase.split == "calibration" else {
            continue
        }
        let baseline = try #require(runtimeCase.sample.expected)
        let baselineMetrics = try await pointwise.metrics(
            subject: ModelSubject(value: baseline),
            input: runtimeCase.sample
        )
        checkJudgeMetrics(
            baselineMetrics,
            requestedDimensionCount: 3
        )

        _ = try await pairwise.judgePrompt(
            for: runtimeCase.sample,
            output: runtimeCase.candidate
        )
        let pairwiseMetrics = try await pairwise.metrics(
            subject: ModelSubject(value: runtimeCase.candidate),
            input: runtimeCase.sample
        )
        checkJudgeMetrics(
            pairwiseMetrics,
            requestedDimensionCount: 1
        )
    }
}

@available(macOS 27.0, *)
@Test(
    "Both makeSamples overloads execute only in the model lane",
    .enabled(if: advancedJudgeRuntimeEnabled)
)
func advancedMakeSamplesOverloadsRuntime() async throws {
    let model = SystemLanguageModel()
    #expect(
        model.isAvailable,
        "The opt-in generator lane requires an available system model."
    )
    guard model.isAvailable else {
        return
    }

    var modelSamples: [ModelSample<String>] = []
    for try await sample
        in AdvancedSampleGeneratorCoverage
        .modelSampleMakeSamples(model: model)
    {
        modelSamples.append(sample)
    }
    #expect(!modelSamples.isEmpty)

    var generableSamples: [AdvancedGenerableSample] = []
    for try await sample
        in AdvancedSampleGeneratorCoverage
        .generableSampleMakeSamples(model: model)
    {
        generableSamples.append(sample)
    }
    #expect(!generableSamples.isEmpty)
}
