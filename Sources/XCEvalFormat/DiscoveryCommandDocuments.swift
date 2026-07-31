import Foundation

public struct XCEvalEvaluationsAPISource:
    Codable,
    Equatable,
    Sendable
{
    public let xcodeVersion: String?
    public let xcodeBuild: String?
    public let frameworkPath: String
    public let interfacePath: String
    public let architecture: String
    public let targetTriple: String?
    public let compilerVersion: String?
    public let moduleName: String
}

public struct XCEvalEvaluationsAPISourceLocation:
    Codable,
    Equatable,
    Sendable
{
    public let path: String
    public let startLine: Int
    public let endLine: Int
}

public struct XCEvalEvaluationsAPIAvailability:
    Codable,
    Equatable,
    Sendable
{
    public let platform: String
    public let introducedVersion: String?
    public let isUnavailable: Bool
    public let rawAttribute: String
}

public enum XCEvalEvaluationsAPISymbolKind:
    String,
    Codable,
    Sendable
{
    case actor
    case `class`
    case `enum`
    case `protocol`
    case `struct`
}

public struct XCEvalEvaluationsAPISymbolSummary:
    Codable,
    Equatable,
    Sendable
{
    public let name: String
    public let kind: XCEvalEvaluationsAPISymbolKind
    public let availability: [XCEvalEvaluationsAPIAvailability]
    public let sourceLocation: XCEvalEvaluationsAPISourceLocation
}

public struct XCEvalEvaluationsAPISymbol:
    Codable,
    Equatable,
    Sendable
{
    public let name: String
    public let kind: XCEvalEvaluationsAPISymbolKind
    public let declaration: String
    public let availability: [XCEvalEvaluationsAPIAvailability]
    public let sourceLocation: XCEvalEvaluationsAPISourceLocation
}

public struct XCEvalAPIListDocument: Codable, Equatable, Sendable {
    public static let schema = "xceval.evaluations-api/v1"

    public let schemaVersion: String
    public let command: String
    public let source: XCEvalEvaluationsAPISource
    public let count: Int
    public let symbols: [XCEvalEvaluationsAPISymbolSummary]
}

public struct XCEvalAPIShowDocument: Codable, Equatable, Sendable {
    public static let schema = "xceval.evaluations-api/v1"

    public let schemaVersion: String
    public let command: String
    public let source: XCEvalEvaluationsAPISource
    public let symbol: XCEvalEvaluationsAPISymbol
}

public enum XCEvalAuthoringRecipeKind: String, Codable, Sendable {
    case deterministic
    case modelJudge = "model-judge"
    case session
    case synthetic
    case toolCall = "tool-call"
}

public struct XCEvalAuthoringRequirement:
    Codable,
    Equatable,
    Sendable
{
    public let module: String
    public let symbol: String
    public let purpose: String
}

public struct XCEvalAuthoringSemanticInput:
    Codable,
    Equatable,
    Sendable
{
    public let id: String
    public let description: String
}

public struct XCEvalAuthoringTemplate: Codable, Equatable, Sendable {
    public let relativePath: String
    public let defaultTypeName: String
    public let sourceTemplate: String
}

public struct XCEvalAuthoringCompilationPlan:
    Codable,
    Equatable,
    Sendable
{
    public let mode: String
    public let platform: String
    public let requiredOSVersion: String
    public let requiredFrameworks: [String]
}

public struct XCEvalAuthoringRecipe: Codable, Equatable, Sendable {
    public let id: String
    public let kind: XCEvalAuthoringRecipeKind
    public let summary: String
    public let requirements: [XCEvalAuthoringRequirement]
    public let semanticInputs: [XCEvalAuthoringSemanticInput]
    public let template: XCEvalAuthoringTemplate
    public let compilationPlan: XCEvalAuthoringCompilationPlan
}

public struct XCEvalAPIExampleDocument: Codable, Equatable, Sendable {
    public static let schema = "xceval.authoring-example/v1"

    public let schemaVersion: String
    public let command: String
    public let recipe: XCEvalAuthoringRecipe
    public let typeName: String
    public let source: String
}

public struct XCEvalAuthoringVerificationResult:
    Codable,
    Equatable,
    Sendable
{
    public let recipeID: String
    public let passed: Bool
    public let xcodeVersion: String?
    public let xcodeBuild: String?
    public let interfacePath: String
    public let command: [String]
    public let diagnostics: String
}

public struct XCEvalAPIVerifyDocument: Codable, Equatable, Sendable {
    public static let schema = "xceval.authoring-verification/v1"

    public let schemaVersion: String
    public let command: String
    public let xcode: XCEvalXcodeInstallation
    public let passed: Bool
    public let results: [XCEvalAuthoringVerificationResult]
}

public struct XCEvalEvidenceSample: Codable, Equatable, Sendable {
    public let index: Int
    public let key: XCEvalSampleKey?
    public let input: XCEvalJSONValue?
    public let prompt: String?
    public let response: XCEvalJSONValue?
    public let expected: XCEvalJSONValue?
    public let metrics: [XCEvalSampleMetric]
    public let otherColumns: [String: XCEvalJSONValue]
    public let failedMetrics: [String]
    public let structuralDifferences: [XCEvalValueDifference]
}

public struct XCEvalEvidenceSampleDelta:
    Codable,
    Equatable,
    Sendable
{
    public let classification: XCEvalSampleComparisonClassification
    public let key: XCEvalSampleKey?
    public let baselineSamples: [XCEvalEvidenceSample]
    public let candidateSamples: [XCEvalEvidenceSample]
}

public struct XCEvalEvidenceDocument: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let command: String
    public let artifact: XCEvalArtifactIdentity
    public let baseline: XCEvalArtifactIdentity?
    public let sampleKeyStrategy: XCEvalSampleKeyStrategy
    public let includesStructuralDifferences: Bool
    public let regressionsOnly: Bool
    public let failingSamples: [XCEvalEvidenceSample]
    public let aggregateDeltas: [XCEvalMetricComparison]
    public let sampleDeltas: [XCEvalEvidenceSampleDelta]
}

public struct XCEvalRunDirectoryPlan: Codable, Equatable, Sendable {
    public let runID: String
    public let runsRoot: URL
    public let runDirectory: URL
    public let artifactsDirectory: URL
    public let logsDirectory: URL
    public let provenanceFile: URL
    public let eventsFile: URL
}

public enum XCEvalEnvironmentDisclosure: String, Codable, Sendable {
    case plainText = "plain-text"
    case digest
    case presenceOnly = "presence-only"
}

public struct XCEvalRedactedEnvironmentVariable:
    Codable,
    Equatable,
    Sendable
{
    public let name: String
    public let disclosure: XCEvalEnvironmentDisclosure
    public let value: String?
    public let valueDigest: String?
}

public struct XCEvalRedactedEnvironmentDescriptor:
    Codable,
    Equatable,
    Sendable
{
    public let variables: [XCEvalRedactedEnvironmentVariable]
}

public struct XCEvalProvenanceScaffold: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let runID: String
    public let createdAt: String
    public let integrity: XCEvalJSONValue?
    public let git: XCEvalJSONValue?
    public let toolchain: XCEvalJSONValue?
    public let environment: XCEvalRedactedEnvironmentDescriptor
    public let mutations: [XCEvalJSONValue]
    public let artifacts: [XCEvalJSONValue]
    public let requiredEvidence: [String]
}

public struct XCEvalPlanDocument: Codable, Equatable, Sendable {
    public static let schema = "xceval.plan/v1"

    public let schemaVersion: String
    public let command: String
    public let readOnly: Bool
    public let run: XCEvalRunDirectoryPlan
    public let provenance: XCEvalProvenanceScaffold
}
