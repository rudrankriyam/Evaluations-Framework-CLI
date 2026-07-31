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
    public let artifactID: String?
    public let byteDigest: String?
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
        artifactID: String? = nil,
        byteDigest: String? = nil,
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
        self.artifactID = artifactID
        self.byteDigest = byteDigest
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

/// A supported machine-readable `xceval` JSON document.
public enum XCEvalDocument: Equatable, Sendable {
    case inspect(XCEvalInspectDocument)
    case samples(XCEvalSamplesDocument)
    case capabilities(XCEvalCapabilitiesDocument)
    case doctor(XCEvalDoctorDocument)
    case list(XCEvalListDocument)
    case validate(XCEvalValidationDocument)
    case metrics(XCEvalMetricsDocument)
    case report(XCEvalReportDocument)
    case dataset(XCEvalDatasetDocument)
    case compare(XCEvalCompareDocument)
    case gate(XCEvalGateDocument)
    case convert(XCEvalConvertDocument)
    case run(XCEvalRunDocument)
    case test(XCEvalTestDocument)
    case export(XCEvalExportDocument)
    case pipeline(XCEvalPipelineDocument)
    case initialize(XCEvalInitDocument)
    case targets(XCEvalTargetsDocument)
    case target(XCEvalTargetDetailDocument)
    case error(XCEvalErrorDocument)
    case operation(XCEvalOperationReceipt)
    case selection(XCEvalSelectionDocument)
    case datasetsDiscover(XCEvalDatasetsDiscoverDocument)
    case datasetsValidate(XCEvalDatasetsValidationDocument)
    case datasetsSelect(XCEvalDatasetsSelectDocument)
    case datasetsDraft(XCEvalDatasetsDraftDocument)
    case datasetsPromote(XCEvalDatasetsPromoteDocument)
    case plan(XCEvalPlanDocument)
    case apiList(XCEvalAPIListDocument)
    case apiShow(XCEvalAPIShowDocument)
    case apiExample(XCEvalAPIExampleDocument)
    case apiVerify(XCEvalAPIVerifyDocument)
    case evidence(XCEvalEvidenceDocument)
}

/// Decodes machine-readable `xceval` command output without parsing Apple's
/// persisted evaluation schema.
public enum XCEvalDocumentDecoder {
    public static func decode(_ data: Data) throws -> XCEvalDocument {
        let header = try JSONDecoder().decode(DocumentHeader.self, from: data)
        if header.schemaVersion == XCEvalErrorDocument.schema {
            return .error(
                try JSONDecoder().decode(XCEvalErrorDocument.self, from: data)
            )
        }
        if header.schemaVersion == XCEvalOperationReceipt.schema {
            return .operation(
                try JSONDecoder().decode(XCEvalOperationReceipt.self, from: data)
            )
        }
        guard let command = header.command else {
            throw XCEvalFormatError.unsupportedCommand("<missing>")
        }
        let expectedSchema: String
        switch command {
        case "plan":
            expectedSchema = XCEvalPlanDocument.schema
        case "api list", "api show":
            expectedSchema = XCEvalAPIListDocument.schema
        case "api example":
            expectedSchema = XCEvalAPIExampleDocument.schema
        case "api verify":
            expectedSchema = XCEvalAPIVerifyDocument.schema
        case "pipeline":
            expectedSchema = XCEvalPipelineDocument.schema
        case "init":
            expectedSchema = XCEvalInitDocument.schema
        case "targets":
            expectedSchema = XCEvalTargetsDocument.schema
        case "target":
            expectedSchema = XCEvalTargetDetailDocument.schema
        case "select":
            expectedSchema = XCEvalSelectionDocument.schema
        case "datasets.discover",
            "datasets.select",
            "datasets.draft",
            "datasets.promote":
            expectedSchema = XCEvalDatasetsDiscoverDocument.schema
        case "datasets.validate":
            expectedSchema = XCEvalDatasetsValidationDocument.schema
        default:
            expectedSchema = XCEvalFormatVersion.current
        }
        guard header.schemaVersion == expectedSchema else {
            throw XCEvalFormatError.unsupportedSchema(header.schemaVersion)
        }
        switch command {
        case "plan":
            return .plan(
                try JSONDecoder().decode(XCEvalPlanDocument.self, from: data)
            )
        case "api list":
            return .apiList(
                try JSONDecoder().decode(XCEvalAPIListDocument.self, from: data)
            )
        case "api show":
            return .apiShow(
                try JSONDecoder().decode(XCEvalAPIShowDocument.self, from: data)
            )
        case "api example":
            return .apiExample(
                try JSONDecoder().decode(XCEvalAPIExampleDocument.self, from: data)
            )
        case "api verify":
            return .apiVerify(
                try JSONDecoder().decode(XCEvalAPIVerifyDocument.self, from: data)
            )
        case "inspect":
            return .inspect(
                try JSONDecoder().decode(XCEvalInspectDocument.self, from: data)
            )
        case "samples":
            return .samples(
                try JSONDecoder().decode(XCEvalSamplesDocument.self, from: data)
            )
        case "capabilities":
            return .capabilities(
                try JSONDecoder().decode(
                    XCEvalCapabilitiesDocument.self,
                    from: data
                )
            )
        case "doctor":
            return .doctor(
                try JSONDecoder().decode(XCEvalDoctorDocument.self, from: data)
            )
        case "list":
            return .list(
                try JSONDecoder().decode(XCEvalListDocument.self, from: data)
            )
        case "validate":
            return .validate(
                try JSONDecoder().decode(
                    XCEvalValidationDocument.self,
                    from: data
                )
            )
        case "metrics":
            return .metrics(
                try JSONDecoder().decode(XCEvalMetricsDocument.self, from: data)
            )
        case "report":
            return .report(
                try JSONDecoder().decode(XCEvalReportDocument.self, from: data)
            )
        case "evidence":
            return .evidence(
                try JSONDecoder().decode(XCEvalEvidenceDocument.self, from: data)
            )
        case "dataset":
            return .dataset(
                try JSONDecoder().decode(XCEvalDatasetDocument.self, from: data)
            )
        case "compare":
            return .compare(
                try JSONDecoder().decode(XCEvalCompareDocument.self, from: data)
            )
        case "gate":
            return .gate(
                try JSONDecoder().decode(XCEvalGateDocument.self, from: data)
            )
        case "convert":
            return .convert(
                try JSONDecoder().decode(XCEvalConvertDocument.self, from: data)
            )
        case "run":
            return .run(
                try JSONDecoder().decode(XCEvalRunDocument.self, from: data)
            )
        case "test":
            return .test(
                try JSONDecoder().decode(XCEvalTestDocument.self, from: data)
            )
        case "export":
            return .export(
                try JSONDecoder().decode(XCEvalExportDocument.self, from: data)
            )
        case "pipeline":
            return .pipeline(
                try JSONDecoder().decode(XCEvalPipelineDocument.self, from: data)
            )
        case "init":
            return .initialize(
                try JSONDecoder().decode(XCEvalInitDocument.self, from: data)
            )
        case "targets":
            return .targets(
                try JSONDecoder().decode(XCEvalTargetsDocument.self, from: data)
            )
        case "target":
            return .target(
                try JSONDecoder().decode(
                    XCEvalTargetDetailDocument.self,
                    from: data
                )
            )
        case "select":
            return .selection(
                try JSONDecoder().decode(XCEvalSelectionDocument.self, from: data)
            )
        case "datasets.discover":
            return .datasetsDiscover(
                try JSONDecoder().decode(
                    XCEvalDatasetsDiscoverDocument.self,
                    from: data
                )
            )
        case "datasets.validate":
            return .datasetsValidate(
                try JSONDecoder().decode(
                    XCEvalDatasetsValidationDocument.self,
                    from: data
                )
            )
        case "datasets.select":
            return .datasetsSelect(
                try JSONDecoder().decode(
                    XCEvalDatasetsSelectDocument.self,
                    from: data
                )
            )
        case "datasets.draft":
            return .datasetsDraft(
                try JSONDecoder().decode(
                    XCEvalDatasetsDraftDocument.self,
                    from: data
                )
            )
        case "datasets.promote":
            return .datasetsPromote(
                try JSONDecoder().decode(
                    XCEvalDatasetsPromoteDocument.self,
                    from: data
                )
            )
        default:
            throw XCEvalFormatError.unsupportedCommand(command)
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

    /// Decodes normalized lines emitted by `xceval dataset --output jsonl`.
    public static func decodeDatasetJSONLines(
        _ data: Data
    ) throws -> [XCEvalDatasetLine] {
        let lines = data.split(
            separator: 0x0A,
            omittingEmptySubsequences: false
        )
        var documents: [XCEvalDatasetLine] = []
        for (index, line) in lines.enumerated() {
            guard
                let first = line.firstIndex(where: { !$0.isJSONWhitespace }),
                let last = line.lastIndex(where: { !$0.isJSONWhitespace })
            else {
                continue
            }
            do {
                let document = try JSONDecoder().decode(
                    XCEvalDatasetLine.self,
                    from: Data(line[first...last])
                )
                guard document.schemaVersion == XCEvalFormatVersion.current else {
                    throw XCEvalFormatError.unsupportedSchema(
                        document.schemaVersion
                    )
                }
                documents.append(document)
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
    let command: String?
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
