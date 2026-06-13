import Foundation

public struct EvaluationMetricProfile: Codable, Equatable, Sendable {
    public let name: String
    public let evaluatorKinds: [String]
    public let sampleCount: Int
    public let passCount: Int
    public let failCount: Int
    public let scoreCount: Int
    public let ignoredCount: Int
    public let rationaleCount: Int
    public let numericCount: Int
    public let minimum: Double?
    public let maximum: Double?
    public let mean: Double?
}

public struct EvaluationDatasetRecord: Codable, Equatable, Sendable {
    public let sampleIndex: Int
    public let prompt: String?
    public let response: JSONValue?
    public let expected: JSONValue?
    public let input: JSONValue?
}

public struct EvaluationDatasetPair: Codable, Equatable, Sendable {
    public let input: String
    public let response: String
}

public enum EvaluationValidationSeverity: String, Codable, Sendable {
    case error
    case warning
}

public struct EvaluationValidationIssue: Codable, Equatable, Sendable {
    public let severity: EvaluationValidationSeverity
    public let code: String
    public let message: String
    public let sampleIndex: Int?
    public let metric: String?

    public init(
        severity: EvaluationValidationSeverity,
        code: String,
        message: String,
        sampleIndex: Int? = nil,
        metric: String? = nil
    ) {
        self.severity = severity
        self.code = code
        self.message = message
        self.sampleIndex = sampleIndex
        self.metric = metric
    }
}

public struct EvaluationValidationReport: Codable, Equatable, Sendable {
    public let issues: [EvaluationValidationIssue]

    public var errorCount: Int {
        issues.count { $0.severity == .error }
    }

    public var warningCount: Int {
        issues.count { $0.severity == .warning }
    }

    public var isValid: Bool {
        errorCount == 0
    }
}

extension EvaluationArtifact {
    public var metricProfiles: [EvaluationMetricProfile] {
        var metrics: [String: [EvaluationSampleMetric]] = [:]
        for sample in samples {
            for metric in sample.metrics {
                metrics[metric.name, default: []].append(metric)
            }
        }

        return metrics.keys.sorted().map { name in
            let values = metrics[name] ?? []
            let numericValues = values.compactMap(\.value?.doubleValue)
            let total = numericValues.reduce(0, +)
            return EvaluationMetricProfile(
                name: name,
                evaluatorKinds: Array(
                    Set(values.compactMap(\.evaluatorKind))
                ).sorted(),
                sampleCount: values.count,
                passCount: values.count {
                    $0.kind == "pass" && !$0.failed
                },
                failCount: values.count { $0.failed },
                scoreCount: values.count { $0.kind == "score" },
                ignoredCount: values.count { $0.kind == "ignore" },
                rationaleCount: values.count { $0.rationale != nil },
                numericCount: numericValues.count,
                minimum: numericValues.min(),
                maximum: numericValues.max(),
                mean: numericValues.isEmpty
                    ? nil
                    : total / Double(numericValues.count)
            )
        }
    }

    public var datasetRecords: [EvaluationDatasetRecord] {
        samples.map { sample in
            EvaluationDatasetRecord(
                sampleIndex: sample.index,
                prompt: sample.prompt,
                response: sample.responseValue,
                expected: sample.expected,
                input: sample.input
            )
        }
    }

    public var datasetPairs: [EvaluationDatasetPair] {
        samples.compactMap { sample in
            guard
                let prompt = sample.prompt,
                let response = sample.responseText
            else {
                return nil
            }
            return EvaluationDatasetPair(input: prompt, response: response)
        }
    }

    public func validate() -> EvaluationValidationReport {
        EvaluationValidationReport(
            issues:
                metadataValidationIssues
                + resultValidationIssues
                + metricValidationIssues
        )
    }

    private var metadataValidationIssues: [EvaluationValidationIssue] {
        var issues: [EvaluationValidationIssue] = []
        if evaluationID?.isEmpty != false {
            issues.append(
                EvaluationValidationIssue(
                    severity: .warning,
                    code: "missing_evaluation_id",
                    message: "The artifact has no evaluationID."
                )
            )
        }
        if resultID?.isEmpty != false {
            issues.append(
                EvaluationValidationIssue(
                    severity: .warning,
                    code: "missing_result_id",
                    message: "The artifact has no resultID."
                )
            )
        }
        if let durationInMilliseconds, durationInMilliseconds < 0 {
            issues.append(
                EvaluationValidationIssue(
                    severity: .error,
                    code: "negative_duration",
                    message: "durationInMilliseconds must not be negative."
                )
            )
        }
        return issues
    }

    private var resultValidationIssues: [EvaluationValidationIssue] {
        var issues: [EvaluationValidationIssue] = []
        if rawResultCount != samples.count {
            let invalidCount = rawResultCount - samples.count
            issues.append(
                EvaluationValidationIssue(
                    severity: .error,
                    code: "invalid_sample_rows",
                    message: """
                        \(invalidCount) result row(s) are not JSON objects.
                        """
                )
            )
        }
        if samples.isEmpty {
            issues.append(
                EvaluationValidationIssue(
                    severity: .warning,
                    code: "empty_results",
                    message: "The artifact contains no sample rows."
                )
            )
        }
        if summaries.isEmpty {
            issues.append(
                EvaluationValidationIssue(
                    severity: .warning,
                    code: "empty_summary",
                    message: "The artifact contains no aggregate summary metrics."
                )
            )
        }
        return issues
    }

    private var metricValidationIssues: [EvaluationValidationIssue] {
        var issues: [EvaluationValidationIssue] = []
        let supportedKinds = Set(["pass", "fail", "score", "ignore"])
        for sample in samples {
            for metric in sample.metrics {
                if let kind = metric.kind, !supportedKinds.contains(kind) {
                    issues.append(
                        EvaluationValidationIssue(
                            severity: .warning,
                            code: "unknown_metric_kind",
                            message: "Metric '\(metric.name)' uses unknown kind '\(kind)'.",
                            sampleIndex: sample.index,
                            metric: metric.name
                        )
                    )
                }
            }
        }
        return issues
    }
}

extension EvaluationSample {
    public var prompt: String? {
        input?["input"]?["prompt"]?.stringValue
            ?? input?["prompt"]?.stringValue
            ?? input?["promptDescription"]?.stringValue
    }

    public var responseValue: JSONValue? {
        response?["value"] ?? response
    }

    public var responseText: String? {
        guard let responseValue else { return nil }
        if let value = responseValue.stringValue {
            return value
        }
        guard let data = try? responseValue.encodedData() else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

public struct EvaluationGateRule: Codable, Equatable, Sendable {
    public enum Comparison: String, Codable, Sendable {
        case greaterThan = ">"
        case greaterThanOrEqual = ">="
        case lessThan = "<"
        case lessThanOrEqual = "<="
        case equal = "=="
        case notEqual = "!="
    }

    public let expression: String
    public let metric: String
    public let comparison: Comparison
    public let expected: Double

    public init(_ expression: String) throws {
        let pattern = #"^\s*(.+?)\s*(>=|<=|==|!=|>|<)\s*(-?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)\s*$"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(expression.startIndex..., in: expression)
        guard
            let match = regex.firstMatch(in: expression, range: range),
            match.numberOfRanges == 4,
            let metricRange = Range(match.range(at: 1), in: expression),
            let comparisonRange = Range(match.range(at: 2), in: expression),
            let valueRange = Range(match.range(at: 3), in: expression),
            let comparison = Comparison(
                rawValue: String(expression[comparisonRange])
            ),
            let expected = Double(expression[valueRange])
        else {
            throw EvaluationGateError.invalidRule(expression)
        }

        self.expression = expression
        metric = String(expression[metricRange])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.comparison = comparison
        self.expected = expected
    }

    public func evaluate(
        in artifact: EvaluationArtifact
    ) throws -> EvaluationGateResult {
        let exact = artifact.summaries.filter { $0.name == metric }
        let source = artifact.summaries.filter { $0.sourceMetric == metric }
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
        guard let actual = matches[0].value else {
            throw EvaluationGateError.nonNumericMetric(matches[0].name)
        }
        let passed: Bool
        switch comparison {
        case .greaterThan:
            passed = actual > expected
        case .greaterThanOrEqual:
            passed = actual >= expected
        case .lessThan:
            passed = actual < expected
        case .lessThanOrEqual:
            passed = actual <= expected
        case .equal:
            passed = actual == expected
        case .notEqual:
            passed = actual != expected
        }
        return EvaluationGateResult(
            expression: expression,
            resolvedMetric: matches[0].name,
            actual: actual,
            expected: expected,
            comparison: comparison,
            passed: passed
        )
    }
}

public struct EvaluationGateResult: Codable, Equatable, Sendable {
    public let expression: String
    public let resolvedMetric: String
    public let actual: Double
    public let expected: Double
    public let comparison: EvaluationGateRule.Comparison
    public let passed: Bool
}

public enum EvaluationGateError: LocalizedError {
    case invalidRule(String)
    case metricNotFound(String)
    case ambiguousMetric(String, [String])
    case nonNumericMetric(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRule(let rule):
            """
            Invalid gate rule '\(rule)'. Use an explicit expression such as \
            'Mean of Accuracy>=0.9'.
            """
        case .metricNotFound(let metric):
            "No aggregate metric matches '\(metric)'."
        case .ambiguousMetric(let metric, let matches):
            """
            Metric '\(metric)' is ambiguous. Use one of: \
            \(matches.joined(separator: ", ")).
            """
        case .nonNumericMetric(let metric):
            "Aggregate metric '\(metric)' does not have a numeric value."
        }
    }
}
