import Foundation
import XCEvalFormat

public struct EvaluationArtifact: Sendable {
    public static let schemaVersion = XCEvalFormatVersion.current
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

    /// Digest of canonical sorted-key JSON, invariant to source formatting.
    public var artifactID: String {
        let canonical =
            (try? JSONValue.object(root).encodedData())
            ?? rawData
        return ContentDigest(data: canonical).description
    }

    /// Digest of the exact persisted bytes for provenance and diagnostics.
    public var byteDigest: String {
        ContentDigest(data: rawData).description
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
        let baselineMetrics = summaryMetricsByOccurrence(summaries)
        let candidateMetrics = summaryMetricsByOccurrence(
            candidate.summaries
        )
        let baselineByOccurrence = Dictionary(
            uniqueKeysWithValues: baselineMetrics
        )
        let candidateByOccurrence = Dictionary(
            uniqueKeysWithValues: candidateMetrics
        )
        var occurrences: [SummaryMetricOccurrence] = []
        var seen = Set<SummaryMetricOccurrence>()
        for (occurrence, _) in baselineMetrics + candidateMetrics
        where seen.insert(occurrence).inserted {
            occurrences.append(occurrence)
        }

        return occurrences.map { occurrence in
            let identity = occurrence.identity
            return EvaluationMetricComparison(
                name: identity.name,
                group: identity.group,
                operationType: identity.operationType,
                sourceMetric: identity.sourceMetric,
                occurrence: occurrence.index,
                baseline: baselineByOccurrence[occurrence]?.value,
                candidate: candidateByOccurrence[occurrence]?.value
            )
        }
    }

    public func sampleComparisons(
        with candidate: EvaluationArtifact,
        keyStrategy: EvaluationSampleKeyStrategy,
        includingStructuralDifferences: Bool = false
    ) -> [EvaluationSampleComparison] {
        let baselineGroups = groupedSamples(using: keyStrategy)
        let candidateGroups = candidate.groupedSamples(using: keyStrategy)
        var comparisons: [EvaluationSampleComparison] = []
        var seen = Set<EvaluationSampleKey>()

        for key in baselineGroups.keyOrder {
            seen.insert(key)
            comparisons.append(
                contentsOf: compareSampleGroup(
                    key: key,
                    baseline: baselineGroups.samplesByKey[key] ?? [],
                    candidate: candidateGroups.samplesByKey[key] ?? [],
                    includingStructuralDifferences:
                        includingStructuralDifferences
                )
            )
        }
        for key in candidateGroups.keyOrder where seen.insert(key).inserted {
            comparisons.append(
                contentsOf: compareSampleGroup(
                    key: key,
                    baseline: [],
                    candidate: candidateGroups.samplesByKey[key] ?? [],
                    includingStructuralDifferences:
                        includingStructuralDifferences
                )
            )
        }

        comparisons.append(
            contentsOf: baselineGroups.unkeyed.map {
                EvaluationSampleComparison(
                    classification: .unjoinable,
                    key: nil,
                    baselineSamples: [$0],
                    candidateSamples: []
                )
            })
        comparisons.append(
            contentsOf: candidateGroups.unkeyed.map {
                EvaluationSampleComparison(
                    classification: .unjoinable,
                    key: nil,
                    baselineSamples: [],
                    candidateSamples: [$0]
                )
            })
        return comparisons
    }

    private func groupedSamples(
        using strategy: EvaluationSampleKeyStrategy
    ) -> SampleGroups {
        var samplesByKey: [EvaluationSampleKey: [EvaluationSample]] = [:]
        var keyOrder: [EvaluationSampleKey] = []
        var unkeyed: [EvaluationSample] = []
        for sample in samples {
            guard let key = sample.stableKey(using: strategy) else {
                unkeyed.append(sample)
                continue
            }
            if samplesByKey[key] == nil {
                keyOrder.append(key)
            }
            samplesByKey[key, default: []].append(sample)
        }
        return SampleGroups(
            samplesByKey: samplesByKey,
            keyOrder: keyOrder,
            unkeyed: unkeyed
        )
    }
}

public enum EvaluationSampleComparisonClassification:
    String,
    CaseIterable,
    Codable,
    Equatable,
    Sendable
{
    case regressed
    case fixed
    case changed
    case added
    case removed
    case unjoinable
}

public struct EvaluationSampleComparison:
    Codable,
    Equatable,
    Sendable
{
    public let classification: EvaluationSampleComparisonClassification
    public let key: EvaluationSampleKey?
    public let baselineSamples: [EvaluationSample]
    public let candidateSamples: [EvaluationSample]

    public init(
        classification: EvaluationSampleComparisonClassification,
        key: EvaluationSampleKey?,
        baselineSamples: [EvaluationSample],
        candidateSamples: [EvaluationSample]
    ) {
        self.classification = classification
        self.key = key
        self.baselineSamples = baselineSamples
        self.candidateSamples = candidateSamples
    }
}

private struct SampleGroups {
    let samplesByKey: [EvaluationSampleKey: [EvaluationSample]]
    let keyOrder: [EvaluationSampleKey]
    let unkeyed: [EvaluationSample]
}

private func compareSampleGroup(
    key: EvaluationSampleKey,
    baseline: [EvaluationSample],
    candidate: [EvaluationSample],
    includingStructuralDifferences: Bool
) -> [EvaluationSampleComparison] {
    guard baseline.count <= 1, candidate.count <= 1 else {
        return [
            EvaluationSampleComparison(
                classification: .unjoinable,
                key: key,
                baselineSamples: baseline,
                candidateSamples: candidate
            )
        ]
    }
    guard let baselineSample = baseline.first else {
        return [
            EvaluationSampleComparison(
                classification: .added,
                key: key,
                baselineSamples: [],
                candidateSamples: candidate
            )
        ]
    }
    guard let candidateSample = candidate.first else {
        return [
            EvaluationSampleComparison(
                classification: .removed,
                key: key,
                baselineSamples: baseline,
                candidateSamples: []
            )
        ]
    }

    let baselineFailed = baselineSample.hasFailure(
        includingStructuralDifferences: includingStructuralDifferences
    )
    let candidateFailed = candidateSample.hasFailure(
        includingStructuralDifferences: includingStructuralDifferences
    )
    let classification: EvaluationSampleComparisonClassification?
    if !baselineFailed, candidateFailed {
        classification = .regressed
    } else if baselineFailed, !candidateFailed {
        classification = .fixed
    } else if !baselineSample.hasEquivalentEvidence(to: candidateSample) {
        classification = .changed
    } else {
        classification = nil
    }
    return classification.map {
        [
            EvaluationSampleComparison(
                classification: $0,
                key: key,
                baselineSamples: baseline,
                candidateSamples: candidate
            )
        ]
    } ?? []
}

extension EvaluationSample {
    fileprivate func hasEquivalentEvidence(
        to other: EvaluationSample
    ) -> Bool {
        input == other.input
            && response == other.response
            && expected == other.expected
            && metrics == other.metrics
            && otherColumns == other.otherColumns
    }
}

private struct SummaryMetricIdentity: Hashable {
    let name: String
    let group: String?
    let operationType: String?
    let sourceMetric: String?

    init(_ metric: EvaluationSummaryMetric) {
        name = metric.name
        group = metric.group
        operationType = metric.operationType
        sourceMetric = metric.sourceMetric
    }
}

private struct SummaryMetricOccurrence: Hashable {
    let identity: SummaryMetricIdentity
    let index: Int
}

private func summaryMetricsByOccurrence(
    _ metrics: [EvaluationSummaryMetric]
) -> [(SummaryMetricOccurrence, EvaluationSummaryMetric)] {
    var counts: [SummaryMetricIdentity: Int] = [:]
    return metrics.map { metric in
        let identity = SummaryMetricIdentity(metric)
        let index = counts[identity, default: 0] + 1
        counts[identity] = index
        return (
            SummaryMetricOccurrence(identity: identity, index: index),
            metric
        )
    }
}

public struct EvaluationMetricComparison: Encodable, Equatable, Sendable {
    public let name: String
    public let group: String?
    public let operationType: String?
    public let sourceMetric: String?
    public let occurrence: Int
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
        case occurrence
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
        try container.encode(occurrence, forKey: .occurrence)
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
