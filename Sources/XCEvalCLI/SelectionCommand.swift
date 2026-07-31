import ArgumentParser
import Foundation
import XCEvalCore
import XCEvalFormat

struct SelectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "select",
        abstract: "Persist a stable selected-sample manifest for a producer."
    )

    @Argument(
        help: "Artifact, .xcevalresults.jsonl, directory, or '-' for stdin."
    )
    var path: String

    @Flag(
        name: .long,
        help: "Select only samples containing a failure."
    )
    var onlyFailures = false

    @Flag(
        name: .long,
        help: "Treat Subject-versus-Expected differences as failures."
    )
    var includeStructuralDifferences = false

    @Option(
        name: .long,
        help: """
            RFC 6901 JSON Pointer inside normalized sample input. Without it, \
            the canonical complete-input digest is used.
            """
    )
    var sampleKey: String?

    @Option(
        name: .long,
        help: "Destination for the versioned selection manifest."
    )
    var outputPath: String

    @Flag(
        name: .long,
        help: "Replace an existing selection manifest."
    )
    var force = false

    @OptionGroup var artifactSelection: ArtifactSelectionOptions
    @OptionGroup var outputOptions: StandardOutputOptions

    mutating func run() throws {
        if includeStructuralDifferences, !onlyFailures {
            throw ValidationError(
                "--include-structural-differences requires --only-failures."
            )
        }
        let output = try outputOptions.resolve()
        let artifact = try loadSingleArtifact(
            path: path,
            selection: artifactSelection
        )
        let strategy =
            sampleKey.map(EvaluationSampleKeyStrategy.jsonPointer)
            ?? .canonicalInputDigest
        let candidates =
            onlyFailures
            ? artifact.samples.filter {
                $0.hasFailure(
                    includingStructuralDifferences:
                        includeStructuralDifferences
                )
            }
            : artifact.samples

        var selected: [SelectedEvaluationSample] = []
        var unkeyed: [Int] = []
        for sample in candidates {
            guard let key = sample.stableKey(using: strategy) else {
                unkeyed.append(sample.index)
                continue
            }
            selected.append(
                SelectedEvaluationSample(
                    key: displayKey(key.value),
                    canonicalKey: key.value,
                    index: sample.index,
                    input: sample.input,
                    inputDigest: sample.input.map {
                        ContentDigest(
                            data: (try? $0.encodedData()) ?? Data()
                        ).description
                    }
                )
            )
        }
        guard unkeyed.isEmpty else {
            throw ValidationError(
                "The selected sample key is missing from indices "
                    + unkeyed.map(String.init).joined(separator: ", ")
                    + "."
            )
        }

        let destination = expandedURL(outputPath)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path), !force {
            throw ValidationError(
                "The selection output already exists: \(destination.path)"
            )
        }
        let protectedInputs =
            path == "-"
            ? []
            : [expandedURL(path)]
        try validateForcedReplacement(
            targets: [destination],
            protecting: protectedInputs,
            allowsHomeDirectoryAsRoot: true
        )
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let payload = EvaluationSelectionPayload(
            source: ArtifactIdentity(artifact),
            sampleKey: sampleKey ?? "canonical-input-digest",
            samples: selected,
            outputPath: destination.path
        )
        try encodedJSON(payload).write(to: destination, options: .atomic)

        switch output.format {
        case .text:
            print(
                "Selected \(payload.count) sample(s) into \(destination.path)."
            )
        case .json:
            try CLIOutput.emit(payload, options: output)
        case .jsonl, .rawJSON:
            preconditionFailure("Validated output format is exhaustive.")
        }
    }
}

struct SelectedEvaluationSample: Codable, Equatable, Sendable {
    let key: String
    let canonicalKey: String
    let index: Int
    let input: JSONValue?
    let inputDigest: String?
}

struct EvaluationSelectionPayload: Encodable, Equatable, Sendable {
    let schemaVersion = "xceval.selection/v1"
    let command = "select"
    let source: ArtifactIdentity
    let sampleKey: String
    let count: Int
    let samples: [SelectedEvaluationSample]
    let outputPath: String

    init(
        source: ArtifactIdentity,
        sampleKey: String,
        samples: [SelectedEvaluationSample],
        outputPath: String
    ) {
        self.source = source
        self.sampleKey = sampleKey
        count = samples.count
        self.samples = samples
        self.outputPath = outputPath
    }
}

private func displayKey(_ canonical: String) -> String {
    guard
        let data = canonical.data(using: .utf8),
        let value = try? JSONValue.decode(data),
        let string = value.stringValue
    else {
        return canonical
    }
    return string
}

private func encodedJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [
        .prettyPrinted,
        .sortedKeys,
        .withoutEscapingSlashes
    ]
    var data = try encoder.encode(value)
    data.append(0x0A)
    return data
}
