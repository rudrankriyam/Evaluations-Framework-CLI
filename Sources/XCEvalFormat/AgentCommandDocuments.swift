import Foundation

/// The structured error body emitted for machine-readable command failures.
public struct XCEvalErrorBody: Codable, Equatable, Sendable {
    public let code: String
    public let message: String
    public let retryable: Bool
    public let details: [String: XCEvalJSONValue]
}

/// JSON emitted on stdout when a machine-readable command fails.
public struct XCEvalErrorDocument: Codable, Equatable, Sendable {
    public static let schema = "xceval.error/v1"

    public let schemaVersion: String
    public let command: String
    public let error: XCEvalErrorBody
}

public enum XCEvalOperationReceiptState: String, Codable, Sendable {
    case running
    case succeeded
    case failed
    case cancelled
    case timedOut
}

public struct XCEvalOperationProcessOutcome:
    Codable,
    Equatable,
    Sendable
{
    public let status: Int32
    public let terminationReason: XCEvalProcessTerminationReason
    public let terminationSignal: Int32?
    public let duration: TimeInterval
    public let processIdentifier: Int32
    public let processGroupIdentifier: Int32?
    public let standardOutputLog: String?
    public let standardErrorLog: String?
    public let standardOutputTruncated: Bool
    public let standardErrorTruncated: Bool
}

public struct XCEvalOperationOutputArtifact:
    Codable,
    Equatable,
    Sendable
{
    public let path: String
    public let contentDigest: String?
}

/// The durable receipt emitted by `xceval operation --output json` and nested
/// in idempotent `run` output.
public struct XCEvalOperationReceipt: Codable, Equatable, Sendable {
    public static let schema = "xceval.operation-receipt/v1"

    public let schemaVersion: String
    public let operationID: UUID
    public let idempotencyKey: String
    public let operation: String
    public let attempt: Int
    public let state: XCEvalOperationReceiptState
    public let startedAt: Date
    public let endedAt: Date?
    public let inputDigest: String?
    public let process: XCEvalOperationProcessOutcome?
    public let outputs: [XCEvalOperationOutputArtifact]
    public let errorMessage: String?
}

public struct XCEvalSelectedSample: Codable, Equatable, Sendable {
    public let key: String
    public let canonicalKey: String
    public let index: Int
    public let input: XCEvalJSONValue?
    public let inputDigest: String?
}

/// JSON emitted and persisted by `xceval select`.
public struct XCEvalSelectionDocument: Codable, Equatable, Sendable {
    public static let schema = "xceval.selection/v1"

    public let schemaVersion: String
    public let command: String
    public let source: XCEvalArtifactIdentity
    public let sampleKey: String
    public let count: Int
    public let samples: [XCEvalSelectedSample]
    public let outputPath: String
}

public struct XCEvalDiscoveredDataset: Codable, Equatable, Sendable {
    public let path: String
    public let format: String?
    public let recordCount: Int?
    public let datasetID: String?
    public let loadError: String?
}

/// JSON emitted by `xceval datasets discover`.
public struct XCEvalDatasetsDiscoverDocument:
    Codable,
    Equatable,
    Sendable
{
    public static let schema = "xceval.datasets/v1"

    public let schemaVersion: String
    public let command: String
    public let count: Int
    public let datasets: [XCEvalDiscoveredDataset]
}

public struct XCEvalDatasetValidationIssue:
    Codable,
    Equatable,
    Sendable
{
    public let code: String
    public let recordIndex: Int
    public let message: String
}

/// JSON emitted by `xceval datasets validate`.
public struct XCEvalDatasetsValidationDocument:
    Codable,
    Equatable,
    Sendable
{
    public static let schema = "xceval.dataset-validation/v1"

    public let schemaVersion: String
    public let command: String
    public let path: String
    public let datasetID: String
    public let recordCount: Int
    public let valid: Bool
    public let issues: [XCEvalDatasetValidationIssue]
}

/// JSON emitted by `xceval datasets select`.
public struct XCEvalDatasetsSelectDocument:
    Codable,
    Equatable,
    Sendable
{
    public static let schema = "xceval.datasets/v1"

    public let schemaVersion: String
    public let command: String
    public let sourcePath: String
    public let datasetID: String
    public let selectedCount: Int
    public let missingKeys: [String]
    public let outputPath: String
}

/// JSON emitted by `xceval datasets draft`.
public struct XCEvalDatasetsDraftDocument:
    Codable,
    Equatable,
    Sendable
{
    public static let schema = "xceval.datasets/v1"

    public let schemaVersion: String
    public let command: String
    public let source: XCEvalArtifactIdentity
    public let recordCount: Int
    public let outputPath: String
}

/// JSON emitted by `xceval datasets promote`.
public struct XCEvalDatasetsPromoteDocument:
    Codable,
    Equatable,
    Sendable
{
    public static let schema = "xceval.datasets/v1"

    public let schemaVersion: String
    public let command: String
    public let sourcePath: String
    public let draftPath: String
    public let datasetID: String
    public let addedCount: Int
    public let duplicateCount: Int
    public let outputPath: String
}
