import ArgumentParser
import XCEvalCore
import XCEvalFormat

enum EvidenceOutputFormat: String, CaseIterable, ExpressibleByArgument {
    case json
}

struct EvidenceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "evidence",
        abstract: "Emit compact deterministic failure and comparison evidence."
    )

    @Argument(
        help: "Artifact, .xcevalresults.jsonl, directory, or '-' for stdin."
    )
    var path: String

    @Option(
        name: .long,
        help: "Optional baseline artifact for aggregate and per-sample deltas."
    )
    var baseline: String?

    @Option(
        name: .long,
        help: """
            RFC 6901 JSON Pointer inside each normalized sample input used as \
            cross-run identity. The default is a canonical input digest.
            """
    )
    var sampleKey: String?

    @Flag(
        name: .long,
        help: "Treat Subject-versus-Expected structural differences as failures."
    )
    var includeStructuralDifferences = false

    @Flag(
        name: .long,
        help: "Emit only samples and per-sample deltas classified as regressions."
    )
    var regressionsOnly = false

    @Option(
        name: .long,
        help: "Output format. Evidence supports JSON."
    )
    var output = EvidenceOutputFormat.json

    @Flag(name: .long, help: "Pretty-print JSON output.")
    var pretty = false

    @OptionGroup var selection: ArtifactSelectionOptions

    mutating func run() throws {
        if regressionsOnly, baseline == nil {
            throw ValidationError("--regressions-only requires --baseline.")
        }
        let artifact = try loadSingleArtifact(
            path: path,
            selection: selection
        )
        let baselineArtifact = try baseline.map(loadSingleArtifact)
        let strategy =
            sampleKey.map(EvaluationSampleKeyStrategy.jsonPointer)
            ?? .canonicalInputDigest
        let payload = makeEvidencePayload(
            artifact: artifact,
            baseline: baselineArtifact,
            keyStrategy: strategy,
            includeStructuralDifferences: includeStructuralDifferences,
            regressionsOnly: regressionsOnly
        )
        try CLIOutput.emit(
            payload,
            options: ResolvedOutputOptions(
                format: .json,
                pretty: pretty
            )
        )
    }
}

struct EvidencePayload: Encodable, Equatable {
    let schemaVersion = EvaluationArtifact.schemaVersion
    let command = "evidence"
    let artifact: ArtifactIdentity
    let baseline: ArtifactIdentity?
    let sampleKeyStrategy: EvaluationSampleKeyStrategy
    let includesStructuralDifferences: Bool
    let regressionsOnly: Bool
    let failingSamples: [EvidenceSamplePayload]
    let aggregateDeltas: [EvaluationMetricComparison]
    let sampleDeltas: [EvidenceSampleDeltaPayload]
}

struct EvidenceSamplePayload: Encodable, Equatable {
    let index: Int
    let key: EvaluationSampleKey?
    let input: JSONValue?
    let prompt: String?
    let response: JSONValue?
    let expected: JSONValue?
    let metrics: [EvaluationSampleMetric]
    let otherColumns: [String: JSONValue]
    let failedMetrics: [String]
    let structuralDifferences: [EvaluationValueDifference]

    init(
        sample: EvaluationSample,
        keyStrategy: EvaluationSampleKeyStrategy
    ) {
        index = sample.index
        key = sample.stableKey(using: keyStrategy)
        input = sample.input
        prompt = sample.prompt
        response = sample.response
        expected = sample.expected
        metrics = sample.metrics
        otherColumns = sample.otherColumns
        failedMetrics = sample.metrics.filter(\.failed).map(\.name)
        structuralDifferences = sample.subjectExpectedDifferences
    }
}

struct EvidenceSampleDeltaPayload: Encodable, Equatable {
    let classification: EvaluationSampleComparisonClassification
    let key: EvaluationSampleKey?
    let baselineSamples: [EvidenceSamplePayload]
    let candidateSamples: [EvidenceSamplePayload]

    init(
        comparison: EvaluationSampleComparison,
        keyStrategy: EvaluationSampleKeyStrategy
    ) {
        classification = comparison.classification
        key = comparison.key
        baselineSamples = comparison.baselineSamples.map {
            EvidenceSamplePayload(sample: $0, keyStrategy: keyStrategy)
        }
        candidateSamples = comparison.candidateSamples.map {
            EvidenceSamplePayload(sample: $0, keyStrategy: keyStrategy)
        }
    }
}

func makeEvidencePayload(
    artifact: EvaluationArtifact,
    baseline: EvaluationArtifact?,
    keyStrategy: EvaluationSampleKeyStrategy,
    includeStructuralDifferences: Bool,
    regressionsOnly: Bool
) -> EvidencePayload {
    let comparisons =
        baseline?.sampleComparisons(
            with: artifact,
            keyStrategy: keyStrategy,
            includingStructuralDifferences: includeStructuralDifferences
        ) ?? []
    let selectedComparisons =
        regressionsOnly
        ? comparisons.filter { $0.classification == .regressed }
        : comparisons
    let regressionIndices = Set(
        selectedComparisons
            .filter { $0.classification == .regressed }
            .flatMap(\.candidateSamples)
            .map(\.index)
    )
    let failingSamples = artifact.samples.filter { sample in
        let failed = sample.hasFailure(
            includingStructuralDifferences: includeStructuralDifferences
        )
        return failed && (!regressionsOnly || regressionIndices.contains(sample.index))
    }

    return EvidencePayload(
        artifact: ArtifactIdentity(artifact),
        baseline: baseline.map(ArtifactIdentity.init),
        sampleKeyStrategy: keyStrategy,
        includesStructuralDifferences: includeStructuralDifferences,
        regressionsOnly: regressionsOnly,
        failingSamples: failingSamples.map {
            EvidenceSamplePayload(sample: $0, keyStrategy: keyStrategy)
        },
        aggregateDeltas: baseline?.comparisons(with: artifact) ?? [],
        sampleDeltas: selectedComparisons.map {
            EvidenceSampleDeltaPayload(
                comparison: $0,
                keyStrategy: keyStrategy
            )
        }
    )
}
