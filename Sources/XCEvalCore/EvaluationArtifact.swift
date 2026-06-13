import Foundation

public struct EvaluationArtifact: Sendable {
    public static let schemaVersion = "xceval/v1"
    private static let knownTopLevelFields = Set([
        "durationInMilliseconds",
        "endTime",
        "evaluationID",
        "evaluationInfo",
        "reportMetadata",
        "resultID",
        "results",
        "startTime",
        "summary"
    ])

    public let sourceURL: URL
    public let sourceLine: Int?
    public let rawData: Data
    public let root: [String: JSONValue]

    public init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        try self.init(data: data, sourceURL: url)
    }

    public init(
        data: Data,
        sourceURL: URL = URL(fileURLWithPath: "<memory>"),
        sourceLine: Int? = nil
    ) throws {
        let value: JSONValue
        do {
            value = try JSONValue.decode(data)
        } catch {
            throw EvaluationArtifactError.invalidJSON(error.localizedDescription)
        }
        guard let root = value.objectValue else {
            throw EvaluationArtifactError.expectedObject
        }
        guard root["results"]?.arrayValue != nil else {
            throw EvaluationArtifactError.missingResults
        }

        self.sourceURL = sourceURL
        self.sourceLine = sourceLine
        rawData = data
        self.root = root
    }

    public var sourceDescription: String {
        guard let sourceLine else { return sourceURL.path }
        return "\(sourceURL.path):\(sourceLine)"
    }

    public var evaluationID: String? {
        root["evaluationID"]?.stringValue
    }

    public var resultID: String? {
        root["resultID"]?.stringValue
    }

    public var startTime: String? {
        root["startTime"]?.stringValue
    }

    public var endTime: String? {
        root["endTime"]?.stringValue
    }

    public var durationInMilliseconds: Double? {
        root["durationInMilliseconds"]?.doubleValue
    }

    public var evaluationInfo: [String: JSONValue] {
        root["evaluationInfo"]?.objectValue ?? [:]
    }

    public var reportMetadata: [String: JSONValue] {
        root["reportMetadata"]?.objectValue ?? [:]
    }

    public var otherTopLevelFields: [String: JSONValue] {
        root.filter { !Self.knownTopLevelFields.contains($0.key) }
    }

    public var summaries: [EvaluationSummaryMetric] {
        let rows = root["summary"]?.arrayValue ?? []
        var metrics: [EvaluationSummaryMetric] = []
        for row in rows {
            guard let entries = row.objectValue else { continue }
            metrics.append(
                contentsOf: entries.keys.sorted().compactMap { name in
                    guard let details = entries[name]?.objectValue else { return nil }
                    let operation = details["operation"]?.objectValue
                    return EvaluationSummaryMetric(
                        name: name,
                        group: details["group"]?.stringValue,
                        operationType: operation?["type"]?.stringValue,
                        sourceMetric: operation?["metric"]?.stringValue,
                        value: details["value"]?.doubleValue,
                        details: .object(details)
                    )
                })
        }
        return metrics
    }

    public var samples: [EvaluationSample] {
        let rows = root["results"]?.arrayValue ?? []
        return rows.enumerated().compactMap { index, row in
            guard let columns = row.objectValue else { return nil }
            return EvaluationSample(index: index, columns: columns)
        }
    }

    public var rawResultCount: Int {
        root["results"]?.arrayValue?.count ?? 0
    }

    public func comparisons(
        with candidate: EvaluationArtifact
    ) -> [EvaluationMetricComparison] {
        var baselineByName: [String: EvaluationSummaryMetric] = [:]
        for metric in summaries {
            baselineByName[metric.name] = metric
        }
        var candidateByName: [String: EvaluationSummaryMetric] = [:]
        for metric in candidate.summaries {
            candidateByName[metric.name] = metric
        }
        let names = Set(baselineByName.keys)
            .union(candidateByName.keys)
            .sorted()

        return names.map { name in
            let baseline = baselineByName[name]
            let candidate = candidateByName[name]
            return EvaluationMetricComparison(
                name: name,
                group: candidate?.group ?? baseline?.group,
                operationType: candidate?.operationType ?? baseline?.operationType,
                sourceMetric: candidate?.sourceMetric ?? baseline?.sourceMetric,
                baseline: baseline?.value,
                candidate: candidate?.value
            )
        }
    }
}

public struct EvaluationSummaryMetric: Codable, Equatable, Sendable {
    public let name: String
    public let group: String?
    public let operationType: String?
    public let sourceMetric: String?
    public let value: Double?
    public let details: JSONValue
}

public struct EvaluationSampleMetric: Codable, Equatable, Sendable {
    public let name: String
    public let evaluatorKind: String?
    public let kind: String?
    public let value: JSONValue?
    public let rationale: String?
    public let details: JSONValue

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

    init(index: Int, columns: [String: JSONValue]) {
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
        for name in columns.keys.sorted() where !Self.reservedColumns.contains(name) {
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

public struct EvaluationMetricComparison: Encodable, Equatable, Sendable {
    public let name: String
    public let group: String?
    public let operationType: String?
    public let sourceMetric: String?
    public let baseline: Double?
    public let candidate: Double?

    public var delta: Double? {
        guard let baseline, let candidate else { return nil }
        return candidate - baseline
    }

    public var relativeDelta: Double? {
        guard let baseline, let delta, baseline != 0 else { return nil }
        return delta / abs(baseline)
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case group
        case operationType
        case sourceMetric
        case baseline
        case candidate
        case delta
        case relativeDelta
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(group, forKey: .group)
        try container.encodeIfPresent(operationType, forKey: .operationType)
        try container.encodeIfPresent(sourceMetric, forKey: .sourceMetric)
        try container.encode(baseline, forKey: .baseline)
        try container.encode(candidate, forKey: .candidate)
        try container.encode(delta, forKey: .delta)
        try container.encode(relativeDelta, forKey: .relativeDelta)
    }
}

public enum EvaluationArtifactError: LocalizedError {
    case invalidJSON(String)
    case expectedObject
    case missingResults

    public var errorDescription: String? {
        switch self {
        case .invalidJSON(let message):
            "The evaluation artifact is not valid JSON: \(message)"
        case .expectedObject:
            "The evaluation artifact must contain a top-level JSON object."
        case .missingResults:
            "The JSON object is not an evaluation artifact because it has no results array."
        }
    }
}
