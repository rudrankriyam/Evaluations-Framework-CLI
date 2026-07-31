import Foundation

/// The current normalized JSON contract emitted by `xceval`.
public enum XCEvalFormatVersion {
    public static let current = "xceval/v1"
}

/// Namespaced aliases for normalized values.
public typealias XCEvalJSONValue = JSONValue
public typealias XCEvalSample = EvaluationSample
public typealias XCEvalSampleMetric = EvaluationSampleMetric
public typealias XCEvalSummaryMetric = EvaluationSummaryMetric

/// The normalized artifact contained in `xceval inspect` output.
public struct XCEvalArtifactDocument: Codable, Equatable, Sendable {
    public let path: String
    public let evaluationID: String?
    public let resultID: String?
    public let startTime: String?
    public let endTime: String?
    public let durationInMilliseconds: Double?
    public let sampleCount: Int
    public let info: [String: XCEvalJSONValue]
    public let reportMetadata: [String: XCEvalJSONValue]
    public let otherFields: [String: XCEvalJSONValue]
    public let summary: [XCEvalSummaryMetric]
    public let samples: [XCEvalSample]?

    public init(
        path: String,
        evaluationID: String?,
        resultID: String?,
        startTime: String?,
        endTime: String?,
        durationInMilliseconds: Double?,
        sampleCount: Int,
        info: [String: XCEvalJSONValue],
        reportMetadata: [String: XCEvalJSONValue],
        otherFields: [String: XCEvalJSONValue],
        summary: [XCEvalSummaryMetric],
        samples: [XCEvalSample]?
    ) {
        self.path = path
        self.evaluationID = evaluationID
        self.resultID = resultID
        self.startTime = startTime
        self.endTime = endTime
        self.durationInMilliseconds = durationInMilliseconds
        self.sampleCount = sampleCount
        self.info = info
        self.reportMetadata = reportMetadata
        self.otherFields = otherFields
        self.summary = summary
        self.samples = samples
    }
}

/// Normalized JSON emitted by `xceval inspect --output json`.
public struct XCEvalInspectDocument: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let command: String
    public let artifact: XCEvalArtifactDocument

    public init(artifact: XCEvalArtifactDocument) {
        schemaVersion = XCEvalFormatVersion.current
        command = "inspect"
        self.artifact = artifact
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        command = try container.decode(String.self, forKey: .command)
        try validateHeader(
            schemaVersion: schemaVersion,
            command: command,
            expectedCommand: "inspect",
            codingPath: decoder.codingPath
        )
        let decodedArtifact = try container.decode(
            XCEvalArtifactDocument.self,
            forKey: .artifact
        )
        try validateSampleCount(
            declared: decodedArtifact.sampleCount,
            actual: decodedArtifact.samples?.count,
            codingPath: decoder.codingPath + [CodingKeys.artifact]
        )
        artifact = decodedArtifact
    }
}

/// Normalized JSON emitted by `xceval samples --output json`.
public struct XCEvalSamplesDocument: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let command: String
    public let path: String
    public let evaluationID: String?
    public let resultID: String?
    public let sampleCount: Int
    public let samples: [XCEvalSample]

    public init(
        path: String,
        evaluationID: String?,
        resultID: String?,
        samples: [XCEvalSample]
    ) {
        schemaVersion = XCEvalFormatVersion.current
        command = "samples"
        self.path = path
        self.evaluationID = evaluationID
        self.resultID = resultID
        sampleCount = samples.count
        self.samples = samples
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        command = try container.decode(String.self, forKey: .command)
        try validateHeader(
            schemaVersion: schemaVersion,
            command: command,
            expectedCommand: "samples",
            codingPath: decoder.codingPath
        )
        path = try container.decode(String.self, forKey: .path)
        evaluationID = try container.decodeIfPresent(
            String.self,
            forKey: .evaluationID
        )
        resultID = try container.decodeIfPresent(
            String.self,
            forKey: .resultID
        )
        sampleCount = try container.decode(Int.self, forKey: .sampleCount)
        samples = try container.decode([XCEvalSample].self, forKey: .samples)
        try validateSampleCount(
            declared: sampleCount,
            actual: samples.count,
            codingPath: decoder.codingPath + [CodingKeys.sampleCount]
        )
    }
}

/// One normalized line emitted by `xceval samples --output jsonl`.
public struct XCEvalSampleLine: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let evaluationID: String?
    public let resultID: String?
    public let sample: XCEvalSample

    public init(
        evaluationID: String?,
        resultID: String?,
        sample: XCEvalSample
    ) {
        schemaVersion = XCEvalFormatVersion.current
        self.evaluationID = evaluationID
        self.resultID = resultID
        self.sample = sample
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        guard schemaVersion == XCEvalFormatVersion.current else {
            throw unsupportedSchema(
                schemaVersion,
                codingPath: decoder.codingPath + [CodingKeys.schemaVersion]
            )
        }
        evaluationID = try container.decodeIfPresent(
            String.self,
            forKey: .evaluationID
        )
        resultID = try container.decodeIfPresent(
            String.self,
            forKey: .resultID
        )
        sample = try container.decode(XCEvalSample.self, forKey: .sample)
    }
}

/// A supported normalized `xceval/v1` JSON document.
public enum XCEvalDocument: Equatable, Sendable {
    case inspect(XCEvalInspectDocument)
    case samples(XCEvalSamplesDocument)
}

/// Decodes normalized `xceval/v1` command output without parsing Apple's
/// persisted evaluation schema.
public enum XCEvalDocumentDecoder {
    public static func decode(_ data: Data) throws -> XCEvalDocument {
        let header = try JSONDecoder().decode(DocumentHeader.self, from: data)
        guard header.schemaVersion == XCEvalFormatVersion.current else {
            throw XCEvalFormatError.unsupportedSchema(header.schemaVersion)
        }
        switch header.command {
        case "inspect":
            return .inspect(
                try JSONDecoder().decode(XCEvalInspectDocument.self, from: data)
            )
        case "samples":
            return .samples(
                try JSONDecoder().decode(XCEvalSamplesDocument.self, from: data)
            )
        default:
            throw XCEvalFormatError.unsupportedCommand(header.command)
        }
    }

    public static func decodeJSONLines(
        _ data: Data
    ) throws -> [XCEvalSampleLine] {
        let lines = data.split(
            separator: 0x0A,
            omittingEmptySubsequences: false
        )
        var documents: [XCEvalSampleLine] = []
        for (index, line) in lines.enumerated() {
            guard
                let first = line.firstIndex(where: { !$0.isJSONWhitespace }),
                let last = line.lastIndex(where: { !$0.isJSONWhitespace })
            else {
                continue
            }
            do {
                documents.append(
                    try JSONDecoder().decode(
                        XCEvalSampleLine.self,
                        from: Data(line[first...last])
                    )
                )
            } catch {
                throw XCEvalFormatError.invalidJSONLine(
                    line: index + 1,
                    message: error.localizedDescription
                )
            }
        }
        return documents
    }
}

public enum XCEvalFormatError: LocalizedError, Equatable, Sendable {
    case unsupportedSchema(String)
    case unsupportedCommand(String)
    case invalidJSONLine(line: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let schema):
            """
            Unsupported xceval schema '\(schema)'; expected \
            '\(XCEvalFormatVersion.current)'.
            """
        case .unsupportedCommand(let command):
            "Unsupported normalized xceval command '\(command)'."
        case .invalidJSONLine(let line, let message):
            "Invalid normalized xceval JSON at line \(line): \(message)"
        }
    }
}

private struct DocumentHeader: Decodable {
    let schemaVersion: String
    let command: String
}

private func validateHeader(
    schemaVersion: String,
    command: String,
    expectedCommand: String,
    codingPath: [any CodingKey]
) throws {
    guard schemaVersion == XCEvalFormatVersion.current else {
        throw unsupportedSchema(
            schemaVersion,
            codingPath: codingPath
        )
    }
    guard command == expectedCommand else {
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: codingPath,
                debugDescription: """
                    Expected normalized xceval command '\(expectedCommand)', \
                    found '\(command)'.
                    """
            )
        )
    }
}

private func unsupportedSchema(
    _ schemaVersion: String,
    codingPath: [any CodingKey]
) -> DecodingError {
    DecodingError.dataCorrupted(
        DecodingError.Context(
            codingPath: codingPath,
            debugDescription: """
                Unsupported xceval schema '\(schemaVersion)'; expected \
                '\(XCEvalFormatVersion.current)'.
                """
        )
    )
}

private func validateSampleCount(
    declared: Int,
    actual: Int?,
    codingPath: [any CodingKey]
) throws {
    guard let actual, declared != actual else { return }
    throw DecodingError.dataCorrupted(
        DecodingError.Context(
            codingPath: codingPath,
            debugDescription: """
                sampleCount is \(declared), but the document contains \(actual) \
                samples.
                """
        )
    )
}

extension UInt8 {
    fileprivate var isJSONWhitespace: Bool {
        self == 0x20 || self == 0x09 || self == 0x0A || self == 0x0D
    }
}
