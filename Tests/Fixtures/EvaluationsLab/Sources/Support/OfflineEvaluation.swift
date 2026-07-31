import Evaluations
import Foundation

public enum HarnessMetric {
    public static let exactMatch = Metric("exact_match")
    public static let lengthDelta = Metric("length_delta")
}

public struct TextSample: SampleProtocol, Equatable {
    public let input: String
    public let expected: String?
    public let identifier: String

    public init(input: String, expected: String?, identifier: String) {
        self.input = input
        self.expected = expected
        self.identifier = identifier
    }
}

public struct ExactMatchEvaluator: EvaluatorProtocol {
    public init() {}

    nonisolated public func metrics(
        subject: ModelSubject<String>,
        input: TextSample
    ) async throws -> [Metric] {
        guard let expected = input.expected else {
            return [HarnessMetric.exactMatch.ignore(rationale: "No reference value")]
        }

        if subject.value == expected {
            return [HarnessMetric.exactMatch.passing(rationale: "Exact reference match")]
        }

        return [HarnessMetric.exactMatch.failing(rationale: "Reference mismatch")]
    }
}

public struct LengthDeltaEvaluator: EvaluatorProtocol {
    public init() {}

    nonisolated public func metrics(
        subject: ModelSubject<String>,
        input: TextSample
    ) async throws -> [Metric] {
        guard let expected = input.expected else {
            return [HarnessMetric.lengthDelta.ignore(rationale: "No reference value")]
        }

        let delta = abs(subject.value.count - expected.count)
        return [HarnessMetric.lengthDelta.scoring(Double(delta))]
    }
}

public struct OfflineEvaluation<Dataset: Loader>: Evaluation
where Dataset.Sample == TextSample {
    public let dataset: Dataset

    public init(dataset: Dataset) {
        self.dataset = dataset
    }

    nonisolated public func subject(
        from sample: TextSample
    ) async throws -> ModelSubject<String> {
        ModelSubject(value: sample.input.uppercased())
    }

    public var evaluators: Evaluators {
        ExactMatchEvaluator()
        LengthDeltaEvaluator()
    }

    public func aggregateMetrics(using aggregator: inout MetricsAggregator) {
        aggregator.computeMean(of: HarnessMetric.exactMatch)
        aggregator.computeMean(of: HarnessMetric.lengthDelta)
        aggregator.computeMaximum(of: HarnessMetric.lengthDelta)
        aggregator.custom(of: HarnessMetric.lengthDelta, label: "range") { values in
            guard let minimum = values.min(), let maximum = values.max() else {
                return 0
            }
            return maximum - minimum
        }
        aggregator.group("quality") { group in
            group.computeMean(of: HarnessMetric.exactMatch)
            group.computeMinimum(of: HarnessMetric.lengthDelta)
        }
    }
}

public enum OfflineFixtures {
    public static let samples = [
        TextSample(input: "alpha", expected: "ALPHA", identifier: "passing"),
        TextSample(input: "beta", expected: "BETA!", identifier: "failing"),
        TextSample(input: "gamma", expected: nil, identifier: "ignored")
    ]

    public static var arrayLoader: ArrayLoader<TextSample> {
        ArrayLoader(samples: samples)
    }

    public static var evaluation: OfflineEvaluation<ArrayLoader<TextSample>> {
        OfflineEvaluation(dataset: arrayLoader)
    }

    public static func writeSamplesJSON(to url: URL) throws {
        let data = try JSONEncoder().encode(samples)
        try data.write(to: url, options: .atomic)
    }

    public static func throwingStream() -> AsyncThrowingStream<TextSample, Error> {
        AsyncThrowingStream { continuation in
            for sample in samples {
                continuation.yield(sample)
            }
            continuation.finish()
        }
    }

    public static func collect<L: Loader>(_ loader: L) async throws -> [L.Sample] {
        var samples: [L.Sample] = []
        for try await sample in loader.stream {
            samples.append(sample)
        }
        return samples
    }
}
