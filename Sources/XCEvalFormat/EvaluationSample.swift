import Foundation

public struct EvaluationSummaryMetric: Codable, Equatable, Sendable {
    public let name: String
    public let group: String?
    public let operationType: String?
    public let sourceMetric: String?
    public let value: Double?
    public let details: JSONValue

    public init(
        name: String,
        group: String?,
        operationType: String?,
        sourceMetric: String?,
        value: Double?,
        details: JSONValue
    ) {
        self.name = name
        self.group = group
        self.operationType = operationType
        self.sourceMetric = sourceMetric
        self.value = value
        self.details = details
    }
}

public struct EvaluationSampleMetric: Codable, Equatable, Sendable {
    public let name: String
    public let evaluatorKind: String?
    public let kind: String?
    public let value: JSONValue?
    public let rationale: String?
    public let details: JSONValue

    public init(
        name: String,
        evaluatorKind: String?,
        kind: String?,
        value: JSONValue?,
        rationale: String?,
        details: JSONValue
    ) {
        self.name = name
        self.evaluatorKind = evaluatorKind
        self.kind = kind
        self.value = value
        self.rationale = rationale
        self.details = details
    }

    public var failed: Bool {
        if kind == "fail" {
            return true
        }
        if kind == "pass", value?.boolValue == false {
            return true
        }
        return false
    }
}

public struct EvaluationSample: Codable, Equatable, Sendable {
    private static let reservedColumns = Set(["Input", "Response", "Expected"])

    public let index: Int
    public let input: JSONValue?
    public let inputRaw: String?
    public let response: JSONValue?
    public let expected: JSONValue?
    public let metrics: [EvaluationSampleMetric]
    public let otherColumns: [String: JSONValue]

    public init(
        index: Int,
        input: JSONValue?,
        inputRaw: String?,
        response: JSONValue?,
        expected: JSONValue?,
        metrics: [EvaluationSampleMetric],
        otherColumns: [String: JSONValue]
    ) {
        self.index = index
        self.input = input
        self.inputRaw = inputRaw
        self.response = response
        self.expected = expected
        self.metrics = metrics
        self.otherColumns = otherColumns
    }

    package init(index: Int, columns: [String: JSONValue]) {
        self.index = index
        inputRaw = columns["Input"]?.stringValue
        if let inputRaw, let decoded = JSONValue.decodeJSONString(inputRaw) {
            input = decoded
        } else {
            input = columns["Input"]
        }
        response = columns["Response"]
        expected = columns["Expected"]

        var metrics: [EvaluationSampleMetric] = []
        var otherColumns: [String: JSONValue] = [:]
        for name in columns.keys.sorted()
        where !Self.reservedColumns.contains(name) {
            guard let value = columns[name] else { continue }
            guard
                let details = value.objectValue,
                details["kind"]?.stringValue != nil
                    || details["evaluatorKind"]?.stringValue != nil
            else {
                otherColumns[name] = value
                continue
            }
            metrics.append(
                EvaluationSampleMetric(
                    name: name,
                    evaluatorKind: details["evaluatorKind"]?.stringValue,
                    kind: details["kind"]?.stringValue,
                    value: details["value"],
                    rationale: details["rationale"]?.stringValue,
                    details: value
                )
            )
        }
        self.metrics = metrics
        self.otherColumns = otherColumns
    }

    public var hasFailure: Bool {
        metrics.contains(where: \.failed)
    }
}
