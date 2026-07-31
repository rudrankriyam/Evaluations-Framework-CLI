import Evaluations
import Foundation
import FoundationModels

@available(macOS 27.0, *)
enum AdvancedCoverageScoreLevel: Int, CaseIterable, ScoreLevel {
    case poor = 1
    case fair = 2
    case good = 3
    case excellent = 4

    var guideDescription: String {
        switch self {
        case .poor:
            "Incorrect or unusable."
        case .fair:
            "Partially correct, with major omissions."
        case .good:
            "Correct and useful, with minor omissions."
        case .excellent:
            "Fully correct, concise, and directly useful."
        }
    }

    var value: Double {
        Double(rawValue)
    }
}

@available(macOS 27.0, *)
enum AdvancedModelJudgeCoverage {
    static let relevance = ScoreDimension(
        "Relevance",
        description: "Does the response directly address the request?",
        scale: .numeric([
            1: "Unrelated to the request.",
            2: "Addresses only a small part of the request.",
            3: "Addresses the request with a minor omission.",
            4: "Directly and completely addresses the request."
        ])
    )

    static let safety = ScoreDimension(
        "Safety",
        description: "Does the response avoid unsafe instructions?",
        scale: .passFail(
            passDescription: "The response is safe and appropriately bounded.",
            failDescription: "The response contains unsafe or unbounded guidance."
        )
    )

    static let clarity = ScoreDimension(
        "Clarity",
        description: "Is the response understandable and well organized?",
        scale: .custom(AdvancedCoverageScoreLevel.self)
    )

    static let pointwisePrompt = ModelJudgePrompt<ModelSample<String>>(
        instructions: """
            Evaluate the response using only observable evidence. Return a score \
            for every requested dimension and explain the score briefly.
            """,
        evaluationTarget: { response in
            "Candidate response:\n\(response)"
        },
        reference: { sample, response in
            [
                "Prompt": sample.promptDescription,
                "Expected": sample.expected ?? "No reference answer",
                "Candidate": response
            ]
        }
    )

    // All public Beta 4 pointwise constructor families compile here.
    static let singleDimensionDefaultJudge =
        ModelJudgeEvaluator<ModelSample<String>>(
            "Overall Quality",
            scale: .custom(AdvancedCoverageScoreLevel.self)
        )

    static let singleDimensionCustomPrompt =
        ModelJudgeEvaluator<ModelSample<String>>(
            "Pointwise Quality",
            scale: .numeric([
                0: "Incorrect.",
                0.5: "Partially correct.",
                1: "Correct."
            ]),
            judge: SystemLanguageModel.default,
            scoringMode: .continuous,
            prompt: pointwisePrompt
        )

    static let multipleDimensionsDefaultJudge =
        ModelJudgeEvaluator<ModelSample<String>>(
            dimensions: [relevance, safety, clarity],
            scoringMode: .discrete
        )

    static let multipleDimensionsCustomPrompt =
        ModelJudgeEvaluator<ModelSample<String>>(
            judge: SystemLanguageModel.default,
            dimensions: [relevance, safety, clarity],
            scoringMode: .continuous,
            prompt: pointwisePrompt
        )

    // Pairwise evaluation uses ModelSample.expected as its baseline.
    static let pairwiseSingleDimension =
        ModelJudgeEvaluator<ModelSample<String>>.pairwise(
            "Candidate versus Baseline",
            scale: .numeric([
                1: "The baseline is substantially better.",
                2: "The baseline is slightly better.",
                3: "The candidate is slightly better.",
                4: "The candidate is substantially better."
            ]),
            judge: SystemLanguageModel.default,
            scoringMode: .discrete,
            evaluationTarget: { response in
                "Response:\n\(response)"
            }
        )

    static let pairwiseMultipleDimensions =
        ModelJudgeEvaluator<ModelSample<String>>.pairwise(
            judge: SystemLanguageModel.default,
            dimensions: [relevance, clarity],
            scoringMode: .continuous,
            evaluationTarget: { response in response }
        )
}

@available(macOS 27.0, *)
struct AdvancedAggregationEvaluation: Evaluation {
    let exactMatch = Metric("Exact Match")
    let responseLength = Metric("Response Length")
    let optionalReference = Metric("Optional Reference")

    let dataset = ArrayLoader(samples: [
        ModelSample(prompt: "alpha", expected: "ALPHA"),
        ModelSample(prompt: "missing reference")
    ])

    func subject(
        from sample: ModelSample<String>
    ) async throws -> ModelSubject<String> {
        ModelSubject(value: sample.promptDescription.uppercased())
    }

    var evaluators: Evaluators {
        Evaluator { sample, subject in
            guard let expected = sample.expected else {
                return optionalReference.ignore(
                    rationale: "This sample intentionally has no reference value."
                )
            }
            return subject.value == expected
                ? exactMatch.passing(rationale: "The response matched exactly.")
                : exactMatch.failing(
                    rationale: "Expected \(expected), received \(subject.value)."
                )
        }

        Evaluator { _, subject in
            responseLength.scoring(
                Double(subject.value.count),
                rationale: "Character count of the deterministic response."
            )
        }
    }

    func aggregateMetrics(using aggregator: inout MetricsAggregator) {
        aggregator.group("Correctness") { group in
            group.computeMean(of: exactMatch)
            group.computeMean(of: optionalReference)
        }
        aggregator.group("Response Length Distribution") { group in
            group.computeMean(of: responseLength)
            group.computeMedian(of: responseLength)
            group.computeMode(of: responseLength)
            group.computeMinimum(of: responseLength)
            group.computeMaximum(of: responseLength)
            group.computeVariance(of: responseLength)
            group.computeStandardDeviation(of: responseLength)
            group.custom(
                of: responseLength,
                label: "Response Length Range"
            ) { values in
                guard
                    let minimum = values.min(),
                    let maximum = values.max()
                else {
                    return 0
                }
                return maximum - minimum
            }
        }
        aggregator.custom(
            of: responseLength,
            label: "Nonzero Response Fraction"
        ) { values in
            guard !values.isEmpty else { return 0 }
            return Double(values.count(where: { $0 > 0 }))
                / Double(values.count)
        }
    }
}

@available(macOS 27.0, *)
enum AdvancedCoverageIntentionalError: Error {
    case evaluatorFailure
}

@available(macOS 27.0, *)
enum AdvancedErrorCoverage {
    static let ignored = Evaluator<ModelSample<String>> { sample, _ in
        let metric = Metric("Reference Present")
        guard sample.expected != nil else {
            return metric.ignore(rationale: "Missing expected value.")
        }
        return metric.passing()
    }

    static let throwing = Evaluator<ModelSample<String>> { _, _ in
        throw AdvancedCoverageIntentionalError.evaluatorFailure
    }

    static func frameworkErrors() -> [any Error] {
        [
            EvaluationError.missingTranscript(
                evaluatorType: "Advanced Tool Evaluator"
            ),
            SubjectInferenceError.failed(
                reason: "The subject intentionally failed."
            ),
            EvaluatorError.failed(
                evaluator: nil,
                evaluatorType: "Advanced Custom Evaluator",
                reason: "The evaluator intentionally failed."
            ),
            ModelJudgeError.invalidScore(
                dimension: "Relevance",
                value: "outside-scale"
            ),
            ModelJudgeError.invalidResponse("Malformed judge response."),
            ModelJudgeError.jsonDecodingFailed(
                response: "{not-json}",
                underlying: AdvancedCoverageIntentionalError.evaluatorFailure
            ),
            ModelJudgeError.missingDimension(
                "Safety",
                response: #"{"Relevance":4}"#
            ),
            ModelJudgeError.noScaleValues(dimension: "Empty Scale")
        ]
    }
}
