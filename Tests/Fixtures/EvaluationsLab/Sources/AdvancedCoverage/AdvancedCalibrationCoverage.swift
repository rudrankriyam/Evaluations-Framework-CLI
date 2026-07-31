import Evaluations
import Foundation

@available(macOS 27.0, *)
struct AdvancedRatingInput: Codable, CustomStringConvertible, Sendable {
    let label: String
    let judgeRating: Int

    var description: String {
        "\(label): recorded judge rating \(judgeRating)"
    }
}

@available(macOS 27.0, *)
struct AdvancedRatingSample: Codable, SampleProtocol, Sendable {
    let input: AdvancedRatingInput
    let expected: Int?
}

@available(macOS 27.0, *)
enum AdvancedAgreementAnalytics {
    static func agreementRate(
        expertRatings: [Int],
        judgeRatings: [Int]
    ) -> Double {
        guard
            expertRatings.count == judgeRatings.count,
            !expertRatings.isEmpty
        else {
            return 0
        }

        let agreements = zip(expertRatings, judgeRatings).count {
            $0 == $1
        }
        return Double(agreements) / Double(expertRatings.count)
    }

    static func cohensKappa(
        expertRatings: [Int],
        judgeRatings: [Int]
    ) -> Double {
        guard
            expertRatings.count == judgeRatings.count,
            !expertRatings.isEmpty
        else {
            return 0
        }

        let sampleCount = Double(expertRatings.count)
        let observedAgreement = agreementRate(
            expertRatings: expertRatings,
            judgeRatings: judgeRatings
        )
        let categories = Set(expertRatings).union(judgeRatings)
        let expectedAgreement = categories.reduce(into: 0.0) {
            result,
            category in
            let expertFrequency =
                Double(expertRatings.count { $0 == category }) / sampleCount
            let judgeFrequency =
                Double(judgeRatings.count { $0 == category }) / sampleCount
            result += expertFrequency * judgeFrequency
        }

        guard expectedAgreement < 1 else {
            return observedAgreement == 1 ? 1 : 0
        }
        return (observedAgreement - expectedAgreement)
            / (1 - expectedAgreement)
    }

    static func decodeRatingPairs(
        _ encodedPairs: [Double]
    ) -> (expert: [Int], judge: [Int]) {
        encodedPairs.reduce(into: (expert: [], judge: [])) {
            result,
            encodedPair in
            let pair = Int(encodedPair.rounded())
            result.expert.append(pair / 10)
            result.judge.append(pair % 10)
        }
    }
}

@available(macOS 27.0, *)
struct AdvancedJudgeAgreementEvaluation: Evaluation {
    static let agreement = Metric("Expert/Judge Agreement")
    static let absoluteError = Metric("Expert/Judge Absolute Error")
    static let judgeRating = Metric("Recorded Judge Rating")
    static let encodedRatingPair = Metric("Encoded Expert/Judge Rating Pair")

    let split: String
    let ratings: [(expert: Int, judge: Int)]

    var dataset: ArrayLoader<AdvancedRatingSample> {
        ArrayLoader(
            samples: ratings.enumerated().map { index, ratings in
                AdvancedRatingSample(
                    input: AdvancedRatingInput(
                        label: "\(split)-\(index)",
                        judgeRating: ratings.judge
                    ),
                    expected: ratings.expert
                )
            }
        )
    }

    func subject(
        from sample: AdvancedRatingSample
    ) async throws -> ModelSubject<Int> {
        ModelSubject(value: sample.input.judgeRating)
    }

    var evaluators: Evaluators {
        Evaluator { sample, subject in
            guard let expertRating = sample.expected else {
                return Self.agreement.ignore(
                    rationale: "The expert rating is missing."
                )
            }
            return subject.value == expertRating
                ? Self.agreement.passing(
                    rationale: "The judge agreed with the expert."
                )
                : Self.agreement.failing(
                    rationale:
                        "Expert rated \(expertRating); judge rated \(subject.value)."
                )
        }

        Evaluator { sample, subject in
            guard let expertRating = sample.expected else {
                return Self.absoluteError.ignore(
                    rationale: "The expert rating is missing."
                )
            }
            return Self.absoluteError.scoring(
                Double(abs(expertRating - subject.value)),
                rationale: "Absolute distance between the two ratings."
            )
        }

        Evaluator { _, subject in
            Self.judgeRating.scoring(Double(subject.value))
        }

        Evaluator { sample, subject in
            guard let expertRating = sample.expected else {
                return Self.encodedRatingPair.ignore()
            }
            return Self.encodedRatingPair.scoring(
                Double(expertRating * 10 + subject.value)
            )
        }
    }

    func aggregateMetrics(using aggregator: inout MetricsAggregator) {
        aggregator.group("\(split) Agreement") { group in
            group.computeMean(of: Self.agreement)
            group.computeMean(of: Self.absoluteError)
            group.custom(
                of: Self.encodedRatingPair,
                label: "\(split) Cohen's Kappa"
            ) { encodedPairs in
                let ratings =
                    AdvancedAgreementAnalytics
                    .decodeRatingPairs(encodedPairs)
                return AdvancedAgreementAnalytics.cohensKappa(
                    expertRatings: ratings.expert,
                    judgeRatings: ratings.judge
                )
            }
        }

        aggregator.group("\(split) Judge Distribution") { group in
            group.computeMean(of: Self.judgeRating)
            group.computeStandardDeviation(of: Self.judgeRating)
        }
    }
}

@available(macOS 27.0, *)
enum AdvancedCalibrationFixtures {
    static let calibration: [(expert: Int, judge: Int)] = [
        (1, 1),
        (2, 2),
        (3, 3),
        (4, 4),
        (4, 3),
        (3, 3),
        (2, 2),
        (1, 1)
    ]

    static let holdout: [(expert: Int, judge: Int)] = [
        (1, 1),
        (1, 2),
        (2, 2),
        (2, 2),
        (3, 3),
        (3, 4),
        (4, 4),
        (4, 4)
    ]
}

@available(macOS 27.0, *)
struct AdvancedComparisonSummary: Equatable, Sendable {
    let baselineMean: Double
    let candidateMean: Double
    let meanDelta: Double
    let candidateWins: Int
    let ties: Int
    let baselineWins: Int
}

@available(macOS 27.0, *)
enum AdvancedComparisonAnalytics {
    static func summarize(
        baseline: [Double],
        candidate: [Double]
    ) -> AdvancedComparisonSummary? {
        guard baseline.count == candidate.count, !baseline.isEmpty else {
            return nil
        }

        var candidateWins = 0
        var ties = 0
        var baselineWins = 0
        for (baselineScore, candidateScore) in zip(baseline, candidate) {
            if candidateScore > baselineScore {
                candidateWins += 1
            } else if candidateScore == baselineScore {
                ties += 1
            } else {
                baselineWins += 1
            }
        }

        let baselineMean = baseline.reduce(0, +) / Double(baseline.count)
        let candidateMean = candidate.reduce(0, +) / Double(candidate.count)
        return AdvancedComparisonSummary(
            baselineMean: baselineMean,
            candidateMean: candidateMean,
            meanDelta: candidateMean - baselineMean,
            candidateWins: candidateWins,
            ties: ties,
            baselineWins: baselineWins
        )
    }
}
