import Foundation
import XCEvalFormat

public enum EvaluationDatasetInputFormat: String, Codable, Sendable {
    case automatic
    case json
    case jsonLines = "jsonl"
}

public struct EvaluationDatasetRecordCounts:
    Codable,
    Equatable,
    Sendable
{
    public let physical: Int
    public let decoded: Int
    public let accepted: Int

    public init(
        physical: Int,
        decoded: Int,
        accepted: Int
    ) {
        self.physical = physical
        self.decoded = decoded
        self.accepted = accepted
    }

    public var skipped: Int {
        max(0, physical - decoded)
    }

    public var rejectedAfterDecoding: Int {
        max(0, decoded - accepted)
    }

    public var isLossless: Bool {
        physical == decoded && decoded == accepted
    }

    public func validate() throws {
        guard physical >= 0, decoded >= 0, accepted >= 0 else {
            throw EvaluationDatasetValidationError.negativeRecordCount
        }
        guard decoded <= physical, accepted <= decoded else {
            throw EvaluationDatasetValidationError.inconsistentRecordCounts(
                physical: physical,
                decoded: decoded,
                accepted: accepted
            )
        }
    }
}

public enum EvaluationDatasetValidationIssueCode:
    String,
    Codable,
    Sendable
{
    case malformedJSON = "malformed-json"
    case typedDecodingFailed = "typed-decoding-failed"
    case semanticRoundTripMismatch = "semantic-round-trip-mismatch"
    case emptyDataset = "empty-dataset"
}

public struct EvaluationDatasetValidationIssue:
    Codable,
    Equatable,
    Sendable
{
    public let code: EvaluationDatasetValidationIssueCode
    public let recordIndex: Int?
    public let sourceLine: Int?
    public let message: String

    public init(
        code: EvaluationDatasetValidationIssueCode,
        recordIndex: Int? = nil,
        sourceLine: Int? = nil,
        message: String
    ) {
        self.code = code
        self.recordIndex = recordIndex
        self.sourceLine = sourceLine
        self.message = message
    }
}

public struct EvaluationDatasetValidatedRecord<Sample: Sendable>: Sendable {
    public let index: Int
    public let sourceLine: Int?
    public let original: JSONValue
    public let sample: Sample
    public let contentDigest: ContentDigest

    public init(
        index: Int,
        sourceLine: Int?,
        original: JSONValue,
        sample: Sample,
        contentDigest: ContentDigest
    ) {
        self.index = index
        self.sourceLine = sourceLine
        self.original = original
        self.sample = sample
        self.contentDigest = contentDigest
    }
}

public struct EvaluationDatasetValidationReport<Sample: Sendable>: Sendable {
    public let format: EvaluationDatasetFormat
    public let sourceDigest: ContentDigest
    public let canonicalDigest: ContentDigest?
    public let counts: EvaluationDatasetRecordCounts
    public let records: [EvaluationDatasetValidatedRecord<Sample>]
    public let issues: [EvaluationDatasetValidationIssue]

    public init(
        format: EvaluationDatasetFormat,
        sourceDigest: ContentDigest,
        canonicalDigest: ContentDigest?,
        counts: EvaluationDatasetRecordCounts,
        records: [EvaluationDatasetValidatedRecord<Sample>],
        issues: [EvaluationDatasetValidationIssue]
    ) {
        self.format = format
        self.sourceDigest = sourceDigest
        self.canonicalDigest = canonicalDigest
        self.counts = counts
        self.records = records
        self.issues = issues
    }

    public var isValid: Bool {
        issues.isEmpty && counts.isLossless && canonicalDigest != nil
    }

    public func requireValid() throws {
        guard isValid else {
            throw EvaluationDatasetValidationError.invalidDataset(
                physical: counts.physical,
                decoded: counts.decoded,
                accepted: counts.accepted,
                issueCount: issues.count
            )
        }
    }
}

public enum EvaluationDatasetValidator {
    public static func validate<Sample>(
        _ data: Data,
        as sampleType: Sample.Type = Sample.self,
        format requestedFormat: EvaluationDatasetInputFormat = .automatic,
        requireSemanticRoundTrip: Bool = true
    ) throws -> EvaluationDatasetValidationReport<Sample>
    where Sample: Codable & Sendable {
        let format = try resolveFormat(data, requested: requestedFormat)
        let sourceDigest = EvaluationDatasetDigest.sha256(data)
        let inputs = try physicalRecords(in: data, format: format)

        var issues: [EvaluationDatasetValidationIssue] = []
        if inputs.isEmpty {
            issues.append(
                EvaluationDatasetValidationIssue(
                    code: .emptyDataset,
                    message: "The dataset contains no physical sample records."
                )
            )
        }

        var decodedCount = 0
        var records: [EvaluationDatasetValidatedRecord<Sample>] = []
        var parsedValues: [JSONValue] = []
        for input in inputs {
            let value: JSONValue
            do {
                value = try JSONValue.decode(input.data)
                parsedValues.append(value)
            } catch {
                issues.append(
                    EvaluationDatasetValidationIssue(
                        code: .malformedJSON,
                        recordIndex: input.index,
                        sourceLine: input.sourceLine,
                        message: error.localizedDescription
                    )
                )
                continue
            }

            let sample: Sample
            do {
                sample = try JSONDecoder().decode(Sample.self, from: input.data)
                decodedCount += 1
            } catch {
                issues.append(
                    EvaluationDatasetValidationIssue(
                        code: .typedDecodingFailed,
                        recordIndex: input.index,
                        sourceLine: input.sourceLine,
                        message: error.localizedDescription
                    )
                )
                continue
            }

            if requireSemanticRoundTrip {
                let encoded = try canonicalValue(sample)
                guard encoded == value else {
                    issues.append(
                        EvaluationDatasetValidationIssue(
                            code: .semanticRoundTripMismatch,
                            recordIndex: input.index,
                            sourceLine: input.sourceLine,
                            message: """
                                Typed decoding and encoding changed the sample. \
                                Unknown, defaulted, or normalized fields would \
                                not be preserved.
                                """
                        )
                    )
                    continue
                }
            }

            records.append(
                EvaluationDatasetValidatedRecord(
                    index: input.index,
                    sourceLine: input.sourceLine,
                    original: value,
                    sample: sample,
                    contentDigest:
                        try EvaluationDatasetDigest.canonicalJSONValue(value)
                )
            )
        }

        let counts = EvaluationDatasetRecordCounts(
            physical: inputs.count,
            decoded: decodedCount,
            accepted: records.count
        )
        try counts.validate()
        let canonicalDigest =
            issues.isEmpty
            ? try EvaluationDatasetDigest.canonicalRecords(parsedValues)
            : nil

        return EvaluationDatasetValidationReport(
            format: format,
            sourceDigest: sourceDigest,
            canonicalDigest: canonicalDigest,
            counts: counts,
            records: records,
            issues: issues
        )
    }

    private static func resolveFormat(
        _ data: Data,
        requested: EvaluationDatasetInputFormat
    ) throws -> EvaluationDatasetFormat {
        switch requested {
        case .json:
            return .json
        case .jsonLines:
            return .jsonLines
        case .automatic:
            guard let byte = data.firstNonJSONWhitespaceByte else {
                return .jsonLines
            }
            return byte == UInt8(ascii: "[") ? .json : .jsonLines
        }
    }

    private static func physicalRecords(
        in data: Data,
        format: EvaluationDatasetFormat
    ) throws -> [PhysicalRecord] {
        switch format {
        case .json:
            let root: JSONValue
            do {
                root = try JSONValue.decode(data)
            } catch {
                throw EvaluationDatasetValidationError.invalidJSONDocument(
                    error.localizedDescription
                )
            }
            guard let values = root.arrayValue else {
                throw EvaluationDatasetValidationError.expectedJSONArray
            }
            return try values.enumerated().map { index, value in
                PhysicalRecord(
                    index: index,
                    sourceLine: nil,
                    data: try value.encodedData()
                )
            }
        case .jsonLines:
            let lines = data.split(
                separator: UInt8(ascii: "\n"),
                omittingEmptySubsequences: false
            )
            var records: [PhysicalRecord] = []
            for (lineIndex, line) in lines.enumerated() {
                let record = Data(line).trimmingJSONWhitespace()
                guard !record.isEmpty else { continue }
                records.append(
                    PhysicalRecord(
                        index: records.count,
                        sourceLine: lineIndex + 1,
                        data: record
                    )
                )
            }
            return records
        }
    }

    private static func canonicalValue<T: Encodable>(
        _ value: T
    ) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try JSONValue.decode(encoder.encode(value))
    }
}

public enum EvaluationDatasetValidationError: LocalizedError, Equatable {
    case negativeRecordCount
    case inconsistentRecordCounts(
        physical: Int,
        decoded: Int,
        accepted: Int
    )
    case invalidJSONDocument(String)
    case expectedJSONArray
    case invalidDataset(
        physical: Int,
        decoded: Int,
        accepted: Int,
        issueCount: Int
    )

    public var errorDescription: String? {
        switch self {
        case .negativeRecordCount:
            "Dataset record counts must not be negative."
        case .inconsistentRecordCounts(let physical, let decoded, let accepted):
            """
            Dataset record counts are inconsistent: physical=\(physical), \
            decoded=\(decoded), accepted=\(accepted).
            """
        case .invalidJSONDocument(let message):
            "The dataset JSON document is invalid: \(message)"
        case .expectedJSONArray:
            "A JSON dataset must contain a top-level array."
        case .invalidDataset(let physical, let decoded, let accepted, let count):
            """
            Dataset validation failed: physical=\(physical), decoded=\(decoded), \
            accepted=\(accepted), issues=\(count).
            """
        }
    }
}

private struct PhysicalRecord {
    let index: Int
    let sourceLine: Int?
    let data: Data
}

extension Data {
    fileprivate var firstNonJSONWhitespaceByte: UInt8? {
        first(where: { !$0.isJSONWhitespace })
    }

    fileprivate func trimmingJSONWhitespace() -> Data {
        guard
            let first = firstIndex(where: { !$0.isJSONWhitespace }),
            let last = lastIndex(where: { !$0.isJSONWhitespace })
        else {
            return Data()
        }
        return self[first...last]
    }
}

extension UInt8 {
    fileprivate var isJSONWhitespace: Bool {
        self == 0x20 || self == 0x09 || self == 0x0A || self == 0x0D
    }
}
