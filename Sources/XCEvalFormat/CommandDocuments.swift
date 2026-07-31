import Foundation

/// The normalized identity emitted for an evaluation artifact.
public struct XCEvalArtifactIdentity: Codable, Equatable, Sendable {
    public let path: String
    public let artifactID: String?
    public let byteDigest: String?
    public let evaluationID: String?
    public let resultID: String?
}

/// The compact artifact description emitted by `list` and `run`.
public struct XCEvalArtifactListItem: Codable, Equatable, Sendable {
    public let path: String
    public let artifactID: String?
    public let byteDigest: String?
    public let evaluationID: String?
    public let resultID: String?
    public let sampleCount: Int
    public let summaryMetricCount: Int
    public let startTime: String?
    public let durationInMilliseconds: Double?
}

/// Normalized JSON emitted by `xceval list --output json`.
public struct XCEvalListDocument: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let command: String
    public let count: Int
    public let artifacts: [XCEvalArtifactListItem]
}

public enum XCEvalValidationSeverity: String, Codable, Sendable {
    case error
    case warning
}

public struct XCEvalValidationIssue: Codable, Equatable, Sendable {
    public let severity: XCEvalValidationSeverity
    public let code: String
    public let message: String
    public let sampleIndex: Int?
    public let metric: String?
}

public struct XCEvalArtifactValidation: Codable, Equatable, Sendable {
    public let artifact: XCEvalArtifactIdentity
    public let valid: Bool
    public let errorCount: Int
    public let warningCount: Int
    public let issues: [XCEvalValidationIssue]
}

/// Normalized JSON emitted by `xceval validate --output json`.
public struct XCEvalValidationDocument: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let command: String
    public let valid: Bool
    public let errorCount: Int
    public let warningCount: Int
    public let artifacts: [XCEvalArtifactValidation]
    public let loadError: String?
}

public struct XCEvalMetricProfile: Codable, Equatable, Sendable {
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

/// Normalized JSON emitted by `xceval metrics --output json`.
public struct XCEvalMetricsDocument: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let command: String
    public let artifact: XCEvalArtifactIdentity
    public let profiles: [XCEvalMetricProfile]
    public let summary: [XCEvalSummaryMetric]
}

public enum XCEvalValueDifferenceKind: String, Codable, Sendable {
    case typeMismatch = "type-mismatch"
    case valueMismatch = "value-mismatch"
    case arrayCountMismatch = "array-count-mismatch"
    case missingFromSubject = "missing-from-subject"
    case unexpectedInSubject = "unexpected-in-subject"
}

public struct XCEvalValueDifference: Codable, Equatable, Sendable {
    public let path: String
    public let kind: XCEvalValueDifferenceKind
    public let message: String
    public let subject: XCEvalJSONValue?
    public let expected: XCEvalJSONValue?
}

public struct XCEvalSampleReport: Codable, Equatable, Sendable {
    public let sample: XCEvalSample
    public let failedMetrics: [String]
    public let issues: [XCEvalValueDifference]
}

/// Normalized JSON emitted by `xceval report --output json`.
public struct XCEvalReportDocument: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let command: String
    public let artifact: XCEvalArtifactDocument
    public let profiles: [XCEvalMetricProfile]
    public let samples: [XCEvalSampleReport]
    public let baseline: XCEvalArtifactIdentity?
    public let aggregateComparison: [XCEvalMetricComparison]?
}

public struct XCEvalDatasetRecord: Codable, Equatable, Sendable {
    public let sampleIndex: Int
    public let prompt: String?
    public let response: XCEvalJSONValue?
    public let expected: XCEvalJSONValue?
    public let input: XCEvalJSONValue?
}

/// Normalized JSON emitted by `xceval dataset --output json`.
public struct XCEvalDatasetDocument: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let command: String
    public let artifact: XCEvalArtifactIdentity
    public let rowCount: Int
    public let pairCount: Int
    public let records: [XCEvalDatasetRecord]
}

/// One normalized line emitted by `xceval dataset --output jsonl`.
public struct XCEvalDatasetLine: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let evaluationID: String?
    public let resultID: String?
    public let record: XCEvalDatasetRecord
}

public struct XCEvalMetricComparison: Codable, Equatable, Sendable {
    public let name: String
    public let group: String?
    public let operationType: String?
    public let sourceMetric: String?
    public let occurrence: Int
    public let baseline: Double?
    public let candidate: Double?
    public let delta: Double?
    public let relativeDelta: Double?

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

public enum XCEvalSampleKeyStrategy:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    case jsonPointer(String)
    case canonicalInputDigest
}

public struct XCEvalSampleKey: Codable, Equatable, Hashable, Sendable {
    public let strategy: XCEvalSampleKeyStrategy
    public let value: String
}

public enum XCEvalSampleComparisonClassification:
    String,
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

public struct XCEvalSampleComparison: Codable, Equatable, Sendable {
    public let classification: XCEvalSampleComparisonClassification
    public let key: XCEvalSampleKey?
    public let baselineSamples: [XCEvalSample]
    public let candidateSamples: [XCEvalSample]
}

/// Normalized JSON emitted by `xceval compare --output json`.
public struct XCEvalCompareDocument: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let command: String
    public let baseline: XCEvalArtifactIdentity
    public let candidate: XCEvalArtifactIdentity
    public let metrics: [XCEvalMetricComparison]
    public let sampleKeyStrategy: XCEvalSampleKeyStrategy?
    public let samples: [XCEvalSampleComparison]?
}

public enum XCEvalGateComparison: String, Codable, Sendable {
    case greaterThan = ">"
    case greaterThanOrEqual = ">="
    case lessThan = "<"
    case lessThanOrEqual = "<="
    case equal = "=="
    case notEqual = "!="
}

public struct XCEvalGateResult: Codable, Equatable, Sendable {
    public let expression: String
    public let resolvedMetric: String
    public let actual: Double
    public let expected: Double
    public let comparison: XCEvalGateComparison
    public let passed: Bool
}

public struct XCEvalDeltaGateResult: Codable, Equatable, Sendable {
    public let expression: String
    public let resolvedMetric: String
    public let baseline: Double
    public let candidate: Double
    public let delta: Double
    public let expected: Double
    public let comparison: XCEvalGateComparison
    public let passed: Bool
}

/// Normalized JSON emitted by `xceval gate --output json`.
public struct XCEvalGateDocument: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let command: String
    public let artifact: XCEvalArtifactIdentity
    public let baseline: XCEvalArtifactIdentity?
    public let passed: Bool
    public let rules: [XCEvalGateResult]
    public let deltaRules: [XCEvalDeltaGateResult]?
}

/// Normalized JSON emitted by `xceval convert --output json`.
public struct XCEvalConvertDocument: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let command: String
    public let inputPath: String
    public let format: String
    public let artifactCount: Int
    public let outputPath: String
    public let writtenFiles: [String]
}

public struct XCEvalFrameworkLocation: Codable, Equatable, Sendable {
    public let platform: String
    public let path: String
}

public struct XCEvalXcodeInstallation: Codable, Equatable, Sendable {
    public let applicationPath: String
    public let developerDirectory: String
    public let version: String?
    public let build: String?
    public let frameworks: [XCEvalFrameworkLocation]
    public let exportsEvaluations: Bool
    public let exportSchemaVersion: String?
}

public enum XCEvalCapabilitySupport: String, Codable, Sendable {
    case native
    case orchestrated
    case producerOwned = "producer-owned"
}

public struct XCEvalCapability: Codable, Equatable, Sendable {
    public let name: String
    public let frameworkAPIs: [String]
    public let support: XCEvalCapabilitySupport
    public let command: String
    public let boundary: String
    public let automationUse: String
}

/// Normalized JSON emitted by `xceval capabilities --output json`.
public struct XCEvalCapabilitiesDocument: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let command: String
    public let productName: String
    public let naming: String
    public let affiliation: String
    public let selectedXcode: XCEvalXcodeInstallation?
    public let capabilities: [XCEvalCapability]
}

/// Normalized JSON emitted by `xceval doctor --output json`.
public struct XCEvalDoctorDocument: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let command: String
    public let artifactInspectionAvailable: Bool
    public let evaluationExportAvailable: Bool
    public let selectedXcode: XCEvalXcodeInstallation?
    public let discoveredXcodes: [XCEvalXcodeInstallation]
    public let operatingSystem: String
}

public enum XCEvalProcessTerminationReason: String, Codable, Sendable {
    case exited
    case uncaughtSignal
    case timedOut
    case cancelled
}

public struct XCEvalProcessResult: Codable, Equatable, Sendable {
    public let status: Int32
    public let terminationReason: XCEvalProcessTerminationReason?
    public let terminationSignal: Int32?
    public let duration: TimeInterval?
    public let processIdentifier: Int32?
    public let processGroupIdentifier: Int32?
    public let standardOutput: String
    public let standardError: String
    public let standardOutputLog: String?
    public let standardErrorLog: String?
    public let standardOutputTruncated: Bool?
    public let standardErrorTruncated: Bool?
}

/// Normalized JSON emitted by `xceval run --output json`.
public struct XCEvalRunDocument: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let command: String
    public let producerCommand: [String]
    public let workingDirectory: String?
    public let resultsPath: String
    public let process: XCEvalProcessResult
    public let artifacts: [XCEvalArtifactListItem]
    public let operationReceipt: XCEvalOperationReceipt?
    public let errorMessage: String?
    public let replayed: Bool?
}

/// Normalized JSON emitted by `xceval test --output json`.
public struct XCEvalTestDocument: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let command: String
    public let xcodebuildArguments: [String]
    public let workingDirectory: String?
    public let resultBundlePath: String
    public let outputDirectory: String
    public let xcode: XCEvalXcodeInstallation
    public let process: XCEvalProcessResult
    public let exportedFiles: [String]
    public let manifest: XCEvalJSONValue?
    public let exportError: String?
}

/// Normalized JSON emitted by `xceval export --output json`.
public struct XCEvalExportDocument: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let command: String
    public let xcresultPath: String
    public let outputDirectory: String
    public let xcode: XCEvalXcodeInstallation
    public let onlyFailures: Bool
    public let testID: String?
    public let exportedFiles: [String]
    public let manifest: XCEvalJSONValue?
}

public struct XCEvalPipelineStep: Codable, Equatable, Sendable {
    public let name: String
    public let command: [String]
    public let status: Int32
    public let standardOutputPath: String
    public let standardErrorPath: String
}

/// JSON emitted by `xceval pipeline --output json`.
public struct XCEvalPipelineDocument: Codable, Equatable, Sendable {
    public static let schema = "xceval.pipeline-report/v1"

    public let schemaVersion: String
    public let command: String
    public let name: String
    public let manifestPath: String
    public let workingDirectory: String
    public let resultsPath: String
    public let artifactsDirectory: String
    public let xcode: XCEvalXcodeInstallation?
    public let steps: [XCEvalPipelineStep]
    public let artifact: XCEvalArtifactIdentity?
    public let validation: XCEvalArtifactValidation?
    public let gates: [XCEvalGateResult]
    public let aggregateComparison: [XCEvalMetricComparison]
    public let outputs: [String: String]
    public let passed: Bool
    public let errors: [String]
}

/// JSON emitted by `xceval init --output json`.
public struct XCEvalInitDocument: Codable, Equatable, Sendable {
    public static let schema = "xceval.init/v1"

    public let schemaVersion: String
    public let command: String
    public let name: String
    public let packageName: String
    public let executableName: String
    public let destination: String
    public let files: [String]
}

public enum XCEvalTargetKind: String, Codable, Sendable {
    case command
    case xcodeTest = "xcode-test"
}

public struct XCEvalTargetEnvironment: Codable, Equatable, Sendable {
    public let inherit: [String]
    public let set: [String: String]
}

public enum XCEvalTargetOutputFormat: String, Codable, Sendable {
    case evaluationResult = "xcevalresult"
    case evaluationResultJSONLines = "xcevalresults-jsonl"
    case xcresult
}

public struct XCEvalTargetOutput: Codable, Equatable, Sendable {
    public let role: String
    public let path: String
    public let format: XCEvalTargetOutputFormat
    public let minimumCount: Int?
}

public struct XCEvalTargetRequirement: Codable, Equatable, Sendable {
    public let capability: String
    public let minimumVersion: String?
}

public struct XCEvalTargetDocument: Codable, Equatable, Sendable {
    public let id: String
    public let kind: XCEvalTargetKind
    public let revision: String
    public let workingDirectory: String?
    public let argv: [String]
    public let environment: XCEvalTargetEnvironment?
    public let outputs: [XCEvalTargetOutput]
    public let requirements: [XCEvalTargetRequirement]
    public let sampleKeyPointer: String?
}

/// JSON emitted by `xceval targets --output json`.
public struct XCEvalTargetsDocument: Codable, Equatable, Sendable {
    public static let schema = "xceval.targets/v1"

    public let schemaVersion: String
    public let command: String
    public let manifestPath: String
    public let count: Int
    public let targets: [XCEvalTargetDocument]
}

/// JSON emitted by `xceval target --output json`.
public struct XCEvalTargetDetailDocument: Codable, Equatable, Sendable {
    public static let schema = "xceval.targets/v1"

    public let schemaVersion: String
    public let command: String
    public let manifestPath: String
    public let target: XCEvalTargetDocument
}
