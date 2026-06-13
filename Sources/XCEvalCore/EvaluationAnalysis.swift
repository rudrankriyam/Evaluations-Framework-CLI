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
    public let median: Double?
    public let variance: Double?
    public let standardDeviation: Double?
    public let numericValues: [Double]
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
            let mean =
                numericValues.isEmpty
                ? nil
                : total / Double(numericValues.count)
            let variance = mean.map { mean in
                guard numericValues.count > 1 else { return 0.0 }
                let squaredDifferences = numericValues.reduce(0.0) {
                    partialResult,
                    value in
                    let difference = value - mean
                    return partialResult + difference * difference
                }
                return squaredDifferences
                    / Double(numericValues.count - 1)
            }
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
                mean: mean,
                median: median(of: numericValues),
                variance: variance,
                standardDeviation: variance.map(sqrt),
                numericValues: numericValues
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

    public var subjectExpectedDifferences: [EvaluationValueDifference] {
        guard
            let responseValue,
            let expected,
            expected != .null
        else {
            return []
        }
        return valueDifferences(
            subject: responseValue,
            expected: expected,
            path: "$"
        )
    }
}

public enum EvaluationValueDifferenceKind: String, Codable, Sendable {
    case typeMismatch = "type-mismatch"
    case valueMismatch = "value-mismatch"
    case arrayCountMismatch = "array-count-mismatch"
    case missingFromSubject = "missing-from-subject"
    case unexpectedInSubject = "unexpected-in-subject"
}

public struct EvaluationValueDifference: Codable, Equatable, Sendable {
    public let path: String
    public let kind: EvaluationValueDifferenceKind
    public let message: String
    public let subject: JSONValue?
    public let expected: JSONValue?
}

private func median(of values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
        return (sorted[middle - 1] + sorted[middle]) / 2
    }
    return sorted[middle]
}

private func valueDifferences(
    subject: JSONValue,
    expected: JSONValue,
    path: String
) -> [EvaluationValueDifference] {
    switch (subject, expected) {
    case (.null, .null):
        return []
    case (.bool(let subject), .bool(let expected)):
        return scalarDifference(
            subject: .bool(subject),
            expected: .bool(expected),
            path: path,
            equal: subject == expected
        )
    case (.integer(let subject), .integer(let expected)):
        return scalarDifference(
            subject: .integer(subject),
            expected: .integer(expected),
            path: path,
            equal: subject == expected
        )
    case (.number(let subject), .number(let expected)):
        return scalarDifference(
            subject: .number(subject),
            expected: .number(expected),
            path: path,
            equal: subject == expected
        )
    case (.integer(let subject), .number(let expected)):
        return scalarDifference(
            subject: .integer(subject),
            expected: .number(expected),
            path: path,
            equal: Double(subject) == expected
        )
    case (.number(let subject), .integer(let expected)):
        return scalarDifference(
            subject: .number(subject),
            expected: .integer(expected),
            path: path,
            equal: subject == Double(expected)
        )
    case (.string(let subject), .string(let expected)):
        return scalarDifference(
            subject: .string(subject),
            expected: .string(expected),
            path: path,
            equal: subject == expected
        )
    case (.array(let subject), .array(let expected)):
        var differences: [EvaluationValueDifference] = []
        if subject.count != expected.count {
            differences.append(
                EvaluationValueDifference(
                    path: path,
                    kind: .arrayCountMismatch,
                    message: """
                        Subject has \(subject.count) item(s); expected has \
                        \(expected.count).
                        """,
                    subject: .integer(Int64(subject.count)),
                    expected: .integer(Int64(expected.count))
                )
            )
        }
        for index in 0..<min(subject.count, expected.count) {
            differences.append(
                contentsOf: valueDifferences(
                    subject: subject[index],
                    expected: expected[index],
                    path: "\(path)[\(index)]"
                )
            )
        }
        if subject.count < expected.count {
            for index in subject.count..<expected.count {
                differences.append(
                    EvaluationValueDifference(
                        path: "\(path)[\(index)]",
                        kind: .missingFromSubject,
                        message: "Expected array item is missing from the subject.",
                        subject: nil,
                        expected: expected[index]
                    )
                )
            }
        }
        if expected.count < subject.count {
            for index in expected.count..<subject.count {
                differences.append(
                    EvaluationValueDifference(
                        path: "\(path)[\(index)]",
                        kind: .unexpectedInSubject,
                        message: "Subject contains an unexpected array item.",
                        subject: subject[index],
                        expected: nil
                    )
                )
            }
        }
        return differences
    case (.object(let subject), .object(let expected)):
        var differences: [EvaluationValueDifference] = []
        for key in expected.keys.sorted() {
            let childPath = jsonPath(path, key: key)
            guard let subjectValue = subject[key] else {
                differences.append(
                    EvaluationValueDifference(
                        path: childPath,
                        kind: .missingFromSubject,
                        message: "Expected key is missing from the subject.",
                        subject: nil,
                        expected: expected[key]
                    )
                )
                continue
            }
            differences.append(
                contentsOf: valueDifferences(
                    subject: subjectValue,
                    expected: expected[key] ?? .null,
                    path: childPath
                )
            )
        }
        for key in subject.keys.sorted() where expected[key] == nil {
            differences.append(
                EvaluationValueDifference(
                    path: jsonPath(path, key: key),
                    kind: .unexpectedInSubject,
                    message: "Subject contains an unexpected key.",
                    subject: subject[key],
                    expected: nil
                )
            )
        }
        return differences
    default:
        return [
            EvaluationValueDifference(
                path: path,
                kind: .typeMismatch,
                message: "Subject and expected values use different JSON types.",
                subject: subject,
                expected: expected
            )
        ]
    }
}

private func scalarDifference(
    subject: JSONValue,
    expected: JSONValue,
    path: String,
    equal: Bool
) -> [EvaluationValueDifference] {
    guard !equal else { return [] }
    return [
        EvaluationValueDifference(
            path: path,
            kind: .valueMismatch,
            message: "Subject and expected values do not match.",
            subject: subject,
            expected: expected
        )
    ]
}

private func jsonPath(_ parent: String, key: String) -> String {
    let identifier = key.unicodeScalars.allSatisfy {
        CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "_")
        ).contains($0)
    }
    if identifier,
        key.unicodeScalars.first.map({
            CharacterSet.letters.union(
                CharacterSet(charactersIn: "_")
            ).contains($0)
        }) == true
    {
        return "\(parent).\(key)"
    }
    let escaped =
        key
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "\(parent)[\"\(escaped)\"]"
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
