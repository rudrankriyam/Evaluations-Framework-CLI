import ArgumentParser
import Foundation
import XCEvalCore
import XCEvalFormat

struct DatasetsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "datasets",
        abstract: "Discover, validate, select, draft, and promote datasets.",
        subcommands: [
            DatasetsDiscoverCommand.self,
            DatasetsValidateCommand.self,
            DatasetsSelectCommand.self,
            DatasetsDraftCommand.self,
            DatasetsPromoteCommand.self
        ]
    )
}

struct DatasetsDiscoverCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "discover",
        abstract: "Discover declared-by-convention evaluation datasets."
    )

    @Argument(help: "File or directory to inspect.")
    var path: String

    @OptionGroup var outputOptions: StandardOutputOptions

    mutating func run() throws {
        let output = try outputOptions.resolve()
        let root = expandedURL(path)
        let files = datasetFiles(at: root)
        let datasets = files.map { url in
            let records = try? loadDatasetRecords(url)
            return DiscoveredDataset(
                path: url.path,
                format: records?.format.rawValue,
                recordCount: records?.records.count,
                datasetID: records.map { datasetID($0.records) },
                loadError: records == nil
                    ? "The file is not valid dataset JSON or JSONL."
                    : nil
            )
        }
        let payload = DatasetsDiscoverPayload(datasets: datasets)
        switch output.format {
        case .text:
            for dataset in datasets {
                print(
                    "\(dataset.path)\t"
                        + "\(dataset.recordCount.map(String.init) ?? "invalid")"
                )
            }
        case .json:
            try CLIOutput.emit(payload, options: output)
        case .jsonl, .rawJSON:
            preconditionFailure("Validated output format is exhaustive.")
        }
    }
}

struct DatasetsValidateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Validate physical records and stable dataset identities."
    )

    @Argument(help: "Dataset JSON or JSONL path.")
    var path: String

    @Option(
        name: .long,
        help: "RFC 6901 pointer selecting each record's stable key."
    )
    var sampleKey: String

    @OptionGroup var outputOptions: StandardOutputOptions

    mutating func run() throws {
        let output = try outputOptions.resolve()
        let loaded = try loadDatasetRecords(expandedURL(path))
        var seen = Set<String>()
        var issues: [DatasetValidationIssuePayload] = []
        for (index, record) in loaded.records.enumerated() {
            guard let key = record.value(atJSONPointer: sampleKey) else {
                issues.append(
                    DatasetValidationIssuePayload(
                        code: "missing_sample_key",
                        recordIndex: index,
                        message: "The sample key is missing."
                    )
                )
                continue
            }
            let canonical = key.canonicalJSONString
            if !seen.insert(canonical).inserted {
                issues.append(
                    DatasetValidationIssuePayload(
                        code: "duplicate_sample_key",
                        recordIndex: index,
                        message: "The sample key is duplicated."
                    )
                )
            }
            if record.objectValue?["expected"] == nil {
                issues.append(
                    DatasetValidationIssuePayload(
                        code: "missing_expected",
                        recordIndex: index,
                        message: "The dataset record has no expected value."
                    )
                )
            }
        }
        let payload = DatasetValidationCommandPayload(
            path: expandedURL(path).path,
            datasetID: datasetID(loaded.records),
            recordCount: loaded.records.count,
            valid: issues.isEmpty,
            issues: issues
        )
        switch output.format {
        case .text:
            print(payload.valid ? "Dataset is valid." : "Dataset is invalid.")
            for issue in issues {
                print("[\(issue.code)] record \(issue.recordIndex): \(issue.message)")
            }
        case .json:
            try CLIOutput.emit(payload, options: output)
        case .jsonl, .rawJSON:
            preconditionFailure("Validated output format is exhaustive.")
        }
        if !payload.valid {
            throw ExitCode.failure
        }
    }
}

struct DatasetsSelectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "select",
        abstract: "Materialize dataset records named by a selection manifest."
    )

    @Argument(help: "Dataset JSON or JSONL path.")
    var path: String

    @Option(name: .long, help: "Result-derived selection manifest.")
    var selection: String

    @Option(
        name: .long,
        help: "RFC 6901 pointer selecting each dataset record's stable key."
    )
    var sampleKey: String

    @Option(name: .long, help: "Destination dataset JSON path.")
    var outputPath: String

    @Option(
        name: .customLong("dataset-id"),
        help: "Logical dataset ID used by a versioned lifecycle selection."
    )
    var logicalDatasetID: String?

    @Flag(
        name: .long,
        help: "Permit legacy selections to omit unavailable keys."
    )
    var allowMissing = false

    @Flag(name: .long, help: "Replace an existing destination.")
    var force = false

    @OptionGroup var outputOptions: StandardOutputOptions

    mutating func run() throws {
        let output = try outputOptions.resolve()
        let source = expandedURL(path)
        let selectionSource = expandedURL(selection)
        let loaded = try loadDatasetRecords(source)
        let selectionData = try Data(contentsOf: selectionSource)
        let selectionValue = try JSONValue.decode(selectionData)
        let selected: [JSONValue]
        let missing: [String]

        if selectionValue["cases"] != nil {
            let manifest = try JSONDecoder().decode(
                EvaluationDatasetSelectionManifest.self,
                from: selectionData
            )
            let resolvedDatasetID: String
            if let logicalDatasetID {
                resolvedDatasetID = logicalDatasetID
            } else {
                resolvedDatasetID =
                    try EvaluationDatasetDigest.canonicalRecords(loaded.records)
                    .description
            }
            selected = try EvaluationDatasetLifecycle.select(
                loaded.records,
                sampleKey: sampleKey,
                datasetID: resolvedDatasetID,
                selection: manifest
            )
            missing = []
        } else {
            let requested =
                selectionValue["samples"]?.arrayValue?.compactMap {
                    sample -> (display: String, canonical: String)? in
                    guard let display = sample["key"]?.stringValue else {
                        return nil
                    }
                    return (
                        display,
                        sample["canonicalKey"]?.stringValue
                            ?? JSONValue.string(display).canonicalJSONString
                    )
                } ?? []
            let duplicateKeys = Dictionary(
                grouping: requested,
                by: \.canonical
            ).values.compactMap { requests in
                requests.count > 1 ? requests[0].display : nil
            }.sorted()
            guard duplicateKeys.isEmpty else {
                throw ValidationError(
                    "Selection keys must be unique; duplicates: "
                        + duplicateKeys.joined(separator: ", ")
                        + "."
                )
            }
            let keyed = Dictionary(grouping: loaded.records) { record in
                record.value(atJSONPointer: sampleKey)?.canonicalJSONString
            }
            var resolved: [JSONValue] = []
            var unavailable: [String] = []
            for request in requested {
                let matches = keyed[request.canonical] ?? []
                if matches.isEmpty {
                    unavailable.append(request.display)
                } else if matches.count > 1 {
                    throw ValidationError(
                        "Selection key '\(request.display)' is ambiguous."
                    )
                } else {
                    resolved.append(matches[0])
                }
            }
            if !unavailable.isEmpty, !allowMissing {
                throw ValidationError(
                    "Selection keys are missing: "
                        + unavailable.joined(separator: ", ")
                        + ". Pass --allow-missing to materialize a partial "
                        + "legacy selection."
                )
            }
            selected = resolved
            missing = unavailable
        }
        let destination = expandedURL(outputPath)
        try prepareDatasetDestinations(
            [destination],
            force: force,
            protecting: [source, selectionSource]
        )
        try writeDataset(selected, to: destination)
        let payload = DatasetsSelectPayload(
            sourcePath: source.path,
            datasetID: datasetID(loaded.records),
            selectedCount: selected.count,
            missingKeys: missing,
            outputPath: destination.path
        )
        try emitDatasetMutation(payload, output: output)
    }
}

struct DatasetsDraftCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "draft",
        abstract: "Draft regression cases from persisted evaluation evidence."
    )

    @Argument(help: "Evaluation result artifact.")
    var path: String

    @Flag(name: .long, help: "Draft only failing samples.")
    var onlyFailures = false

    @Option(
        name: .long,
        help: "RFC 6901 pointer selecting stable identity in normalized input."
    )
    var sampleKey: String

    @Option(name: .long, help: "Destination draft dataset JSON path.")
    var outputPath: String

    @Option(
        name: .long,
        help: "Rejected-candidate quarantine path (defaults beside the draft)."
    )
    var quarantinePath: String?

    @Flag(name: .long, help: "Replace an existing destination.")
    var force = false

    @OptionGroup var outputOptions: StandardOutputOptions

    mutating func run() throws {
        let output = try outputOptions.resolve()
        let protectedSource = path == "-" ? nil : expandedURL(path)
        let artifact = try loadSingleArtifact(path: path)
        let strategy = EvaluationSampleKeyStrategy.jsonPointer(sampleKey)
        let sourceSamples =
            onlyFailures
            ? artifact.samples.filter {
                $0.hasFailure(includingStructuralDifferences: true)
            }
            : artifact.samples
        var records: [JSONValue] = []
        var candidates: [EvaluationDatasetDraftCandidate] = []
        for sample in sourceSamples {
            var record: [String: JSONValue] = [
                "input": sample.input ?? .null,
                "sourceSampleIndex": .integer(Int64(sample.index)),
                "sourceResultID": artifact.resultID.map(JSONValue.string) ?? .null
            ]
            if let expected = sample.expected, expected != .null {
                record["expected"] = expected
            }
            let stableKey = sample.stableKey(using: strategy)
            if let stableKey {
                record["id"] = .string(datasetDisplayKeyValue(stableKey.value))
            }
            let draft = EvaluationDatasetCaseDraft(
                draftID: deterministicDraftID(
                    artifactID: artifact.artifactID,
                    sampleIndex: sample.index
                ),
                proposedCaseID: stableKey.map {
                    datasetDisplayKeyValue($0.value)
                },
                category: .knownFailure,
                provenance: EvaluationDatasetCaseProvenance(
                    kind: .imported,
                    source: artifact.artifactID,
                    resultID: artifact.resultID
                ),
                sample: .object(record),
                groundTruthState:
                    sample.expected == nil || sample.expected == .null
                    ? .needsGroundTruth
                    : .preserved
            )
            let reasons =
                stableKey == nil
                ? ["Stable sample key \(sampleKey) is missing."]
                : []
            candidates.append(
                EvaluationDatasetDraftCandidate(
                    draft: draft,
                    rejectionReasons: reasons
                )
            )
            if reasons.isEmpty {
                records.append(.object(record))
            }
        }
        let destination = expandedURL(outputPath)
        let quarantineDestination = expandedURL(
            quarantinePath ?? "\(outputPath).quarantine.json"
        )
        try prepareDatasetDestinations(
            [destination, quarantineDestination],
            force: force,
            protecting: [protectedSource].compactMap(\.self)
        )
        let quarantine = try EvaluationDatasetLifecycle.quarantine(
            runID: artifact.resultID ?? artifact.artifactID,
            datasetID: artifact.evaluationID ?? artifact.artifactID,
            sourceDatasetDigest: try parseContentDigest(artifact.artifactID),
            candidates: candidates
        )
        try writeDataset(records, to: destination)
        try writeDatasetDocument(
            quarantine,
            to: quarantineDestination
        )
        let payload = DatasetsDraftPayload(
            source: ArtifactIdentity(artifact),
            recordCount: records.count,
            rejectedCount: quarantine.rejected.count,
            outputPath: destination.path,
            quarantinePath: quarantineDestination.path,
            draftDigest: try EvaluationDatasetDigest.canonicalRecords(records),
            quarantineDigest:
                try EvaluationDatasetDigest.canonicalJSON(quarantine)
        )
        try emitDatasetMutation(payload, output: output)
    }
}

struct DatasetsPromoteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "promote",
        abstract: "Merge reviewed draft records into a new dataset snapshot."
    )

    @Argument(help: "Reviewed draft dataset JSON path.")
    var draftPath: String

    @Option(name: .long, help: "Existing canonical dataset.")
    var into: String

    @Option(
        name: .long,
        help: "RFC 6901 pointer selecting stable record identity."
    )
    var sampleKey: String

    @Option(name: .long, help: "Destination promoted dataset path.")
    var outputPath: String

    @Option(
        name: .long,
        help: "Required current canonical dataset digest for optimistic concurrency."
    )
    var expectedBaseDigest: String?

    @Flag(name: .long, help: "Replace an existing destination.")
    var force = false

    @OptionGroup var outputOptions: StandardOutputOptions

    mutating func run() throws {
        let output = try outputOptions.resolve()
        let baseSource = expandedURL(into)
        let draftSource = expandedURL(draftPath)
        let base = try loadDatasetRecords(baseSource).records
        let drafts = try loadDatasetRecords(draftSource).records
        let expectedDigest = try expectedBaseDigest.map(parseContentDigest)
        let merged = try EvaluationDatasetLifecycle.merge(
            base: base,
            drafts: drafts,
            sampleKey: sampleKey,
            expectedBaseDatasetDigest: expectedDigest
        )
        let destination = expandedURL(outputPath)
        try prepareDatasetDestinations(
            [destination],
            force: force,
            protecting: [baseSource, draftSource]
        )
        try writeDataset(merged.records, to: destination)
        let payload = DatasetsPromotePayload(
            sourcePath: baseSource.path,
            draftPath: draftSource.path,
            baseDatasetID: merged.baseDatasetDigest.description,
            draftDatasetID: datasetID(drafts),
            datasetID: merged.resultingDatasetDigest.description,
            addedCount: merged.added.count,
            duplicateCount: merged.duplicates.count,
            outputPath: destination.path
        )
        try emitDatasetMutation(payload, output: output)
    }
}

private struct DiscoveredDataset: Encodable {
    let path: String
    let format: String?
    let recordCount: Int?
    let datasetID: String?
    let loadError: String?
}

private struct DatasetsDiscoverPayload: Encodable {
    let schemaVersion = "xceval.datasets/v1"
    let command = "datasets.discover"
    let count: Int
    let datasets: [DiscoveredDataset]

    init(datasets: [DiscoveredDataset]) {
        count = datasets.count
        self.datasets = datasets
    }
}

private struct DatasetValidationIssuePayload: Encodable {
    let code: String
    let recordIndex: Int
    let message: String
}

private struct DatasetValidationCommandPayload: Encodable {
    let schemaVersion = "xceval.dataset-validation/v1"
    let command = "datasets.validate"
    let path: String
    let datasetID: String
    let recordCount: Int
    let valid: Bool
    let issues: [DatasetValidationIssuePayload]
}

private struct DatasetsSelectPayload: Encodable {
    let schemaVersion = "xceval.datasets/v1"
    let command = "datasets.select"
    let sourcePath: String
    let datasetID: String
    let selectedCount: Int
    let missingKeys: [String]
    let outputPath: String
}

private struct DatasetsDraftPayload: Encodable {
    let schemaVersion = "xceval.datasets/v1"
    let command = "datasets.draft"
    let source: ArtifactIdentity
    let recordCount: Int
    let rejectedCount: Int
    let outputPath: String
    let quarantinePath: String
    let draftDigest: ContentDigest
    let quarantineDigest: ContentDigest
}

private struct DatasetsPromotePayload: Encodable {
    let schemaVersion = "xceval.datasets/v1"
    let command = "datasets.promote"
    let sourcePath: String
    let draftPath: String
    let baseDatasetID: String
    let draftDatasetID: String
    let datasetID: String
    let addedCount: Int
    let duplicateCount: Int
    let outputPath: String
}

private struct LoadedDataset {
    let format: EvaluationDatasetFormat
    let records: [JSONValue]
}

private func datasetFiles(at root: URL) -> [URL] {
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory)
    else {
        return []
    }
    if !isDirectory.boolValue {
        return [root]
    }
    guard
        let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
    else {
        return []
    }
    return enumerator.compactMap { item -> URL? in
        guard let url = item as? URL else { return nil }
        let name = url.lastPathComponent
        return name.hasSuffix(".dataset.json")
            || name.hasSuffix(".dataset.jsonl")
            ? url
            : nil
    }.sorted { $0.path < $1.path }
}

private func loadDatasetRecords(_ url: URL) throws -> LoadedDataset {
    let data = try Data(contentsOf: url)
    if let value = try? JSONValue.decode(data), let array = value.arrayValue {
        return LoadedDataset(format: .json, records: array)
    }
    let lines = data.split(separator: 0x0A)
    guard !lines.isEmpty else {
        throw ValidationError("The dataset contains no records: \(url.path)")
    }
    return LoadedDataset(
        format: .jsonLines,
        records: try lines.enumerated().map { index, line in
            do {
                return try JSONValue.decode(Data(line))
            } catch {
                throw ValidationError(
                    "Invalid JSONL record \(index + 1): "
                        + error.localizedDescription
                )
            }
        }
    )
}

private func datasetID(_ records: [JSONValue]) -> String {
    let data = (try? JSONValue.array(records).encodedData()) ?? Data()
    return ContentDigest(data: data).description
}

private func datasetDisplayKey(_ value: JSONValue) -> String {
    value.stringValue ?? value.canonicalJSONString
}

private func datasetDisplayKeyValue(_ canonical: String) -> String {
    guard
        let data = canonical.data(using: .utf8),
        let value = try? JSONValue.decode(data)
    else {
        return canonical
    }
    return datasetDisplayKey(value)
}

private func writeDataset(
    _ records: [JSONValue],
    to url: URL
) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try JSONValue.array(records).encodedData(pretty: true)
        .write(to: url, options: .atomic)
}

private func writeDatasetDocument<Value: Encodable>(
    _ value: Value,
    to url: URL
) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [
        .prettyPrinted,
        .sortedKeys,
        .withoutEscapingSlashes
    ]
    var data = try encoder.encode(value)
    data.append(0x0A)
    try data.write(to: url, options: .atomic)
}

private func prepareDatasetDestinations(
    _ destinations: [URL],
    force: Bool,
    protecting protectedInputs: [URL]
) throws {
    let fileManager = FileManager.default
    if !force,
        let existing = destinations.first(where: {
            fileManager.fileExists(atPath: $0.path)
        })
    {
        throw ValidationError(
            "The dataset output already exists: \(existing.path)"
        )
    }
    try validateForcedReplacement(
        targets: destinations,
        protecting: protectedInputs,
        allowsHomeDirectoryAsRoot: true
    )
}

private func deterministicDraftID(
    artifactID: String,
    sampleIndex: Int
) -> String {
    ContentDigest(
        data: Data("\(artifactID):\(sampleIndex)".utf8)
    ).description
}

private func parseContentDigest(_ value: String) throws -> ContentDigest {
    let prefix = "\(ContentDigest.algorithm):"
    let rawValue =
        value.hasPrefix(prefix)
        ? String(value.dropFirst(prefix.count))
        : value
    guard let digest = ContentDigest(rawValue: rawValue) else {
        throw ValidationError(
            "Expected a lowercase SHA-256 digest, got '\(value)'."
        )
    }
    return digest
}

private func emitDatasetMutation<T: Encodable>(
    _ payload: T,
    output: ResolvedOutputOptions
) throws {
    switch output.format {
    case .text:
        print("Dataset operation completed.")
    case .json:
        try CLIOutput.emit(payload, options: output)
    case .jsonl, .rawJSON:
        preconditionFailure("Validated output format is exhaustive.")
    }
}
