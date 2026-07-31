import Foundation

public struct EvaluationDeltaGateRule: Codable, Equatable, Sendable {
    public let expression: String
    public let metric: String
    public let comparison: EvaluationGateRule.Comparison
    public let expected: Double

    public init(_ expression: String) throws {
        let parsed = try EvaluationGateRule(expression)
        self.expression = expression
        metric = parsed.metric
        comparison = parsed.comparison
        expected = parsed.expected
    }

    public func evaluate(
        baseline: EvaluationArtifact,
        candidate: EvaluationArtifact
    ) throws -> EvaluationDeltaGateResult {
        let comparisons = baseline.comparisons(with: candidate)
        let exact = comparisons.filter { $0.name == metric }
        let source = comparisons.filter { $0.sourceMetric == metric }
        let matches = exact.isEmpty ? source : exact
        guard !matches.isEmpty else {
            throw EvaluationGateError.metricNotFound(metric)
        }
        guard matches.count == 1 else {
            throw EvaluationGateError.ambiguousMetric(
                metric,
                matches.map(\.name)
            )
        }
        guard
            let baselineValue = matches[0].baseline,
            let candidateValue = matches[0].candidate,
            let delta = matches[0].delta
        else {
            throw EvaluationGateError.nonNumericMetric(matches[0].name)
        }

        let passed: Bool
        switch comparison {
        case .greaterThan:
            passed = delta > expected
        case .greaterThanOrEqual:
            passed = delta >= expected
        case .lessThan:
            passed = delta < expected
        case .lessThanOrEqual:
            passed = delta <= expected
        case .equal:
            passed = EvaluationGateRule.approximatelyEqual(delta, expected)
        case .notEqual:
            passed = !EvaluationGateRule.approximatelyEqual(delta, expected)
        }
        return EvaluationDeltaGateResult(
            expression: expression,
            resolvedMetric: matches[0].name,
            baseline: baselineValue,
            candidate: candidateValue,
            delta: delta,
            expected: expected,
            comparison: comparison,
            passed: passed
        )
    }
}

public struct EvaluationDeltaGateResult: Codable, Equatable, Sendable {
    public let expression: String
    public let resolvedMetric: String
    public let baseline: Double
    public let candidate: Double
    public let delta: Double
    public let expected: Double
    public let comparison: EvaluationGateRule.Comparison
    public let passed: Bool

    public init(
        expression: String,
        resolvedMetric: String,
        baseline: Double,
        candidate: Double,
        delta: Double,
        expected: Double,
        comparison: EvaluationGateRule.Comparison,
        passed: Bool
    ) {
        self.expression = expression
        self.resolvedMetric = resolvedMetric
        self.baseline = baseline
        self.candidate = candidate
        self.delta = delta
        self.expected = expected
        self.comparison = comparison
        self.passed = passed
    }
}
