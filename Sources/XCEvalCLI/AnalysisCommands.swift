import ArgumentParser
import Foundation
import XCEvalCore

struct MetricsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "metrics",
        abstract: "Profile evaluator outputs and aggregate metrics."
    )

    @Argument(
        help: "Artifact, .xcevalresults.jsonl, directory, or '-' for stdin."
    )
    var path: String

    @OptionGroup var selection: ArtifactSelectionOptions
    @OptionGroup var outputOptions: StandardOutputOptions

    mutating func run() throws {
        let output = try outputOptions.resolve()
        let artifact = try loadSingleArtifact(
            path: path,
            selection: selection
        )
        let payload = MetricsPayload(artifact: artifact)

        switch output.format {
        case .text:
            for metric in artifact.metricProfiles {
                let mean = metric.mean.map(formattedNumber) ?? "n/a"
                print(
                    "\(metric.name): samples=\(metric.sampleCount) "
                        + "pass=\(metric.passCount) fail=\(metric.failCount) "
                        + "score=\(metric.scoreCount) ignored=\(metric.ignoredCount) "
                        + "mean=\(mean)"
                )
            }
            if !artifact.summaries.isEmpty {
                print("\nAggregate summary:")
                for metric in artifact.summaries {
                    print(
                        "- \(metric.name): "
                            + (metric.value.map(formattedNumber) ?? "non-numeric")
                    )
                }
            }
        case .json:
            try CLIOutput.emit(payload, options: output)
        case .jsonl, .rawJSON:
            preconditionFailure("Validated output format is exhaustive.")
        }
    }
}

enum DatasetOutputFormat: String, CaseIterable, ExpressibleByArgument {
    case text
    case json
    case jsonl
    case appleJSON = "apple-json"
}

struct DatasetOutputOptions: ParsableArguments {
    @Option(
        name: .long,
        help: """
            Output format. apple-json matches Apple's DatasetExtractor \
            prompt/response shape.
            """
    )
    var output: DatasetOutputFormat?

    @Flag(name: .long, help: "Pretty-print JSON output.")
    var pretty = false

    func resolve() throws -> (format: DatasetOutputFormat, pretty: Bool) {
        let format = output ?? (isatty(fileno(stdout)) == 1 ? .text : .json)
        if pretty, format == .text || format == .jsonl {
            throw ValidationError(
                "--pretty is only valid with json or apple-json output."
            )
        }
        return (format, pretty)
    }
}

struct DatasetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dataset",
        abstract: "Extract prompts, responses, expected values, and inputs."
    )

    @Argument(
        help: "Artifact, .xcevalresults.jsonl, directory, or '-' for stdin."
    )
    var path: String

    @OptionGroup var selection: ArtifactSelectionOptions
    @OptionGroup var outputOptions: DatasetOutputOptions

    mutating func run() throws {
        let output = try outputOptions.resolve()
        let artifact = try loadSingleArtifact(
            path: path,
            selection: selection
        )

        switch output.format {
        case .text:
            print(
                "Extracted \(artifact.datasetRecords.count) rows; "
                    + "\(artifact.datasetPairs.count) contain prompt/response pairs."
            )
            for pair in artifact.datasetPairs {
                print("- \(pair.input) -> \(pair.response)")
            }
        case .json:
            try CLIOutput.emit(
                DatasetPayload(artifact: artifact),
                options: ResolvedOutputOptions(
                    format: .json,
                    pretty: output.pretty
                )
            )
        case .jsonl:
            try CLIOutput.emitJSONLines(
                artifact.datasetRecords.map {
                    DatasetLinePayload(
                        evaluationID: artifact.evaluationID,
                        resultID: artifact.resultID,
                        record: $0
                    )
                }
            )
        case .appleJSON:
            try CLIOutput.emit(
                artifact.datasetPairs,
                options: ResolvedOutputOptions(
                    format: .json,
                    pretty: output.pretty
                )
            )
        }
    }
}

enum ConversionFormat: String, CaseIterable, ExpressibleByArgument {
    case jsonl
    case directory
}

struct ConvertCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "convert",
        abstract: "Pack results into JSONL or split a collection into files."
    )

    @Argument(
        help: "Artifact, .xcevalresults.jsonl, directory, or '-' for stdin."
    )
    var path: String

    @Option(
        name: .customLong("to"),
        help: "Conversion target: jsonl or directory."
    )
    var targetFormat: ConversionFormat

    @Option(name: .long, help: "Output file or directory.")
    var outputPath: String

    @Flag(name: .long, help: "Replace an existing output.")
    var force = false

    @OptionGroup var outputOptions: StandardOutputOptions

    mutating func run() throws {
        let output = try outputOptions.resolve()
        let artifacts = try loadArtifacts(path: path)
        let destination = expandedURL(outputPath)
        try prepare(destination)
        let writtenFiles = try write(
            artifacts: artifacts,
            destination: destination
        )

        let payload = ConvertPayload(
            inputPath: path,
            format: targetFormat.rawValue,
            artifactCount: artifacts.count,
            outputPath: destination.path,
            writtenFiles: writtenFiles
        )
        switch output.format {
        case .text:
            print(
                "Wrote \(artifacts.count) artifact(s) to \(destination.path)."
            )
            for file in writtenFiles {
                print("- \(file)")
            }
        case .json:
            try CLIOutput.emit(payload, options: output)
        case .jsonl, .rawJSON:
            preconditionFailure("Validated output format is exhaustive.")
        }
    }

    private func write(
        artifacts: [EvaluationArtifact],
        destination: URL
    ) throws -> [String] {
        switch targetFormat {
        case .jsonl:
            var data = Data()
            for artifact in artifacts {
                data.append(
                    try JSONValue.object(artifact.root).encodedData()
                )
                data.append(0x0A)
            }
            try data.write(to: destination, options: .atomic)
            return [destination.path]
        case .directory:
            return try writeDirectory(
                artifacts: artifacts,
                destination: destination
            )
        }
    }

    private func writeDirectory(
        artifacts: [EvaluationArtifact],
        destination: URL
    ) throws -> [String] {
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        var usedNames = Set<String>()
        var files: [String] = []
        for (index, artifact) in artifacts.enumerated() {
            let stem = sanitizedFileComponent(
                artifact.evaluationID ?? "evaluation-\(index + 1)"
            )
            let result = sanitizedFileComponent(
                artifact.resultID ?? "\(index + 1)"
            )
            var fileName = "\(stem)-\(result).xcevalresult"
            var suffix = 2
            while !usedNames.insert(fileName).inserted {
                fileName = "\(stem)-\(result)-\(suffix).xcevalresult"
                suffix += 1
            }
            let output = destination.appendingPathComponent(fileName)
            try JSONValue.object(artifact.root)
                .encodedData(pretty: true)
                .write(to: output, options: .atomic)
            files.append(output.path)
        }
        return files
    }

    private func prepare(_ destination: URL) throws {
        guard FileManager.default.fileExists(atPath: destination.path) else {
            return
        }
        guard force else {
            throw ValidationError(
                "The output already exists. Pass --force to replace it."
            )
        }
        try FileManager.default.removeItem(at: destination)
    }
}

struct GateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gate",
        abstract: "Fail unless explicit aggregate metric rules pass.",
        discussion: """
            xceval never guesses metric direction. Each rule must include its \
            comparison, for example --rule 'Mean of Accuracy>=0.9' or \
            --rule 'Maximum of Latency<2'.
            """
    )

    @Argument(
        help: "Artifact, .xcevalresults.jsonl, directory, or '-' for stdin."
    )
    var path: String

    @Option(
        name: .long,
        help: "Repeatable explicit aggregate rule, such as 'Mean of Accuracy>=0.9'."
    )
    var rule: [String] = []

    @OptionGroup var selection: ArtifactSelectionOptions
    @OptionGroup var outputOptions: StandardOutputOptions

    mutating func run() throws {
        guard !rule.isEmpty else {
            throw ValidationError("Provide at least one --rule expression.")
        }
        let output = try outputOptions.resolve()
        let artifact = try loadSingleArtifact(
            path: path,
            selection: selection
        )
        let results = try rule.map {
            try EvaluationGateRule($0).evaluate(in: artifact)
        }
        let payload = GatePayload(artifact: artifact, results: results)

        switch output.format {
        case .text:
            for result in results {
                print(
                    "\(result.passed ? "PASS" : "FAIL") "
                        + "\(result.expression) "
                        + "(actual \(formattedNumber(result.actual)))"
                )
            }
        case .json:
            try CLIOutput.emit(payload, options: output)
        case .jsonl, .rawJSON:
            preconditionFailure("Validated output format is exhaustive.")
        }

        if results.contains(where: { !$0.passed }) {
            throw ExitCode.failure
        }
    }
}
