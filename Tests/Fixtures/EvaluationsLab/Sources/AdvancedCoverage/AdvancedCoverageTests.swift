import Evaluations
import Foundation
import FoundationModels
import Testing

private let advancedModelLanesEnabled =
    ProcessInfo.processInfo.environment["EVALUATIONS_LAB_RUN_MODEL_TESTS"] == "1"

@available(macOS 27.0, *)
@Test("Advanced evaluator constructors remain available")
func advancedEvaluatorConstructorsCompile() {
    _ = AdvancedModelJudgeCoverage.singleDimensionDefaultJudge
    _ = AdvancedModelJudgeCoverage.singleDimensionCustomPrompt
    _ = AdvancedModelJudgeCoverage.multipleDimensionsDefaultJudge
    _ = AdvancedModelJudgeCoverage.multipleDimensionsCustomPrompt
    _ = AdvancedModelJudgeCoverage.pairwiseSingleDimension
    _ = AdvancedModelJudgeCoverage.pairwiseMultipleDimensions
    _ = AdvancedErrorCoverage.ignored
    _ = AdvancedErrorCoverage.throwing
    #expect(AdvancedErrorCoverage.frameworkErrors().count == 8)
}

@available(macOS 27.0, *)
@Test("Tool matcher and trajectory constructors remain available")
func advancedToolConstructorsCompile() {
    #expect(AdvancedToolEvaluationCoverage.matcherVariants.count == 9)
    _ = AdvancedToolEvaluationCoverage.orderedWithAnyOrder
    _ = AdvancedToolEvaluationCoverage.unordered
    _ = AdvancedToolEvaluationCoverage.disallowed
    _ = AdvancedToolEvaluationCoverage.allowsAdditionalCalls
    _ = AdvancedToolEvaluationCoverage.rejectsAdditionalCalls
    _ = AdvancedToolEvaluationCoverage.singleTool
    _ = AdvancedToolEvaluationCoverage.deterministicEvaluator
    _ = AdvancedToolEvaluationCoverage.semanticArgumentEvaluator
}

@available(macOS 27.0, *)
@Test("Deterministic ToolCallEvaluator emits its two metrics")
func deterministicToolCallEvaluatorCoverage() async throws {
    let input = ModelSample(
        prompt: "Fetch Cupertino weather.",
        expectations: TrajectoryExpectation(
            expected: "fetch_weather",
            arguments: [
                .exact(argumentName: "city", value: .string("Cupertino")),
                .range(argumentName: "days", minimum: 1, maximum: 10)
            ]
        )
    )
    let subject = ModelSubject(
        value: "done",
        transcript: try AdvancedToolEvaluationCoverage.transcript(
            toolName: "fetch_weather",
            argumentsJSON: #"{"city":"Cupertino","days":5}"#
        )
    )

    let metrics =
        try await AdvancedToolEvaluationCoverage
        .deterministicEvaluator
        .metrics(subject: subject, input: input)

    #expect(metrics.count == 2)
}

@available(macOS 27.0, *)
@Test("A missing transcript reports the framework error")
func missingTranscriptCoverage() async {
    let input = ModelSample(
        prompt: "Fetch Cupertino weather.",
        expectations: TrajectoryExpectation(expected: "fetch_weather")
    )

    do {
        _ =
            try await AdvancedToolEvaluationCoverage
            .deterministicEvaluator
            .metrics(subject: ModelSubject(value: "done"), input: input)
        Issue.record("Expected ToolCallEvaluator to reject a missing transcript.")
    } catch {
        #expect(error is EvaluationError)
    }
}

@available(macOS 27.0, *)
@Test("Custom evaluators cover ignored and thrown outcomes")
func ignoredAndThrownEvaluatorCoverage() async throws {
    let input = ModelSample<String>(prompt: "No reference value.")
    let subject = ModelSubject(value: "response")

    let ignored = try await AdvancedErrorCoverage.ignored.metrics(
        subject: subject,
        input: input
    )
    #expect(ignored.count == 1)
    #expect(ignored[0].value == .ignore)
    #expect(ignored[0].rationale == "Missing expected value.")

    do {
        _ = try await AdvancedErrorCoverage.throwing.metrics(
            subject: subject,
            input: input
        )
        Issue.record("Expected the evaluator to throw its intentional error.")
    } catch {
        #expect(error is AdvancedCoverageIntentionalError)
    }
}

@available(macOS 27.0, *)
@Test("Grouped and custom aggregate declarations execute deterministically")
func groupedAndCustomAggregationCoverage() async throws {
    let result = try await AdvancedAggregationEvaluation().run(
        info: ["Coverage": "Advanced deterministic aggregations"]
    )

    #expect(!result.summary.isEmpty)
    #expect(!result.detailed.isEmpty)
}

@available(macOS 27.0, *)
@Test("Calibration and holdout agreement analytics run offline")
func calibrationAndHoldoutAgreementCoverage() async throws {
    let calibration = AdvancedJudgeAgreementEvaluation(
        split: "Calibration",
        ratings: AdvancedCalibrationFixtures.calibration
    )
    let holdout = AdvancedJudgeAgreementEvaluation(
        split: "Holdout",
        ratings: AdvancedCalibrationFixtures.holdout
    )

    let calibrationResult = try await calibration.run()
    let holdoutResult = try await holdout.run()

    #expect(
        calibrationResult.aggregateValue(
            .custom(label: "Calibration Cohen's Kappa")
        ) == 5.0 / 6.0
    )
    #expect(
        holdoutResult.aggregateValue(
            .custom(label: "Holdout Cohen's Kappa")
        ) == 2.0 / 3.0
    )
    #expect(
        AdvancedAgreementAnalytics.agreementRate(
            expertRatings: AdvancedCalibrationFixtures.calibration.map(
                \.expert
            ),
            judgeRatings: AdvancedCalibrationFixtures.calibration.map(\.judge)
        ) == 0.875
    )
}

@available(macOS 27.0, *)
@Test("Baseline and candidate comparison loops run offline")
func baselineCandidateComparisonCoverage() throws {
    let baseline = [2.0, 3.0, 4.0, 2.0]
    let candidate = [3.0, 3.0, 3.0, 4.0]
    let summary = try #require(
        AdvancedComparisonAnalytics.summarize(
            baseline: baseline,
            candidate: candidate
        )
    )

    #expect(summary.baselineMean == 2.75)
    #expect(summary.candidateMean == 3.25)
    #expect(summary.meanDelta == 0.5)
    #expect(summary.candidateWins == 2)
    #expect(summary.ties == 1)
    #expect(summary.baselineWins == 1)
}

@available(macOS 27.0, *)
@Test("SampleGenerator strategies construct without invoking a model")
func sampleGeneratorConstructorsCompile() {
    _ = AdvancedSampleGeneratorCoverage.randomGenerator()
    _ = AdvancedSampleGeneratorCoverage.slidingWindowGenerator()
    _ = AdvancedSampleGeneratorCoverage.rejectingGenerator()
    _ = AdvancedSampleGeneratorCoverage.modelSampleMakeSamples()
    _ = AdvancedSampleGeneratorCoverage.generableSampleMakeSamples()
}

@available(macOS 27.0, *)
@Test(
    "SampleGenerator invalid-sample runtime coverage is opt in",
    .enabled(if: advancedModelLanesEnabled)
)
func sampleGeneratorInvalidSamplesOptIn() async {
    guard SystemLanguageModel.default.availability == .available else {
        Issue.record(
            "The model-runtime lane was enabled, but the system model is unavailable."
        )
        return
    }

    let generator = AdvancedSampleGeneratorCoverage.rejectingGenerator()
    do {
        for try await _ in generator.run() {}
    } catch {
        // Exhausting retries is allowed for an intentionally rejecting
        // validator. The assertion below verifies that rejected candidates
        // remain observable.
    }

    let invalidSamples = await generator.invalidSamples
    #expect(!invalidSamples.isEmpty)
}
