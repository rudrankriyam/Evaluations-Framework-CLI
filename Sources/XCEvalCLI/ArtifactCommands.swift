import ArgumentParser
import XCEvalCore

struct InspectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Read metadata, aggregate metrics, and sample rows."
    )

    @Argument(
        help: "Artifact, .xcevalresults.jsonl, directory, or '-' for stdin."
    )
    var path: String

    @Flag(
        name: .long,
        help: "Omit per-sample rows from normalized JSON output."
    )
    var summaryOnly = false

    @OptionGroup var selection: ArtifactSelectionOptions
    @OptionGroup var outputOptions: InspectOutputOptions

    mutating func run() throws {
        let output = try outputOptions.resolve()
        let artifact = try loadSingleArtifact(
            path: path,
            selection: selection
        )

        switch output.format {
        case .text:
            printArtifactSummary(artifact)
        case .json:
            try CLIOutput.emit(
                InspectPayload(
                    artifact: ArtifactPayload(
                        artifact: artifact,
                        includeSamples: !summaryOnly
                    )
                ),
                options: output
            )
        case .rawJSON:
            CLIOutput.emitRaw(artifact.rawData)
        case .jsonl:
            preconditionFailure("Validated output format is exhaustive.")
        }
    }
}

struct SamplesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "samples",
        abstract: "Emit normalized per-sample evaluation rows."
    )

    @Argument(
        help: "Artifact, .xcevalresults.jsonl, directory, or '-' for stdin."
    )
    var path: String

    @Flag(
        name: .long,
        help: "Emit only samples containing a failing metric."
    )
    var onlyFailures = false

    @Option(
        name: .long,
        help: "Keep samples containing this metric name."
    )
    var metric: String?

    @Option(
        name: .long,
        help: "Keep samples containing this metric kind: pass, fail, score, or ignore."
    )
    var kind: String?

    @Option(
        name: .long,
        help: "Keep samples containing this evaluator kind."
    )
    var evaluatorKind: String?

    @Option(
        name: .long,
        help: "Keep samples whose decoded prompt contains this text."
    )
    var promptContains: String?

    @Option(
        name: .long,
        help: "Keep samples whose evaluator rationale contains this text."
    )
    var rationaleContains: String?

    @Option(
        name: .long,
        help: "Skip this many matching rows."
    )
    var offset = 0

    @Option(
        name: .long,
        help: "Emit at most this many matching rows."
    )
    var limit: Int?

    @OptionGroup var selection: ArtifactSelectionOptions
    @OptionGroup var outputOptions: SamplesOutputOptions

    mutating func run() throws {
        guard offset >= 0 else {
            throw ValidationError("--offset must not be negative.")
        }
        if let limit, limit < 0 {
            throw ValidationError("--limit must not be negative.")
        }
        let output = try outputOptions.resolve()
        let artifact = try loadSingleArtifact(
            path: path,
            selection: selection
        )
        var samples = artifact.samples.filter(matches)
        samples = Array(samples.dropFirst(offset))
        if let limit {
            samples = Array(samples.prefix(limit))
        }

        switch output.format {
        case .text:
            printSamples(samples)
        case .json:
            try CLIOutput.emit(
                SamplesPayload(
                    path: artifact.sourceDescription,
                    evaluationID: artifact.evaluationID,
                    resultID: artifact.resultID,
                    sampleCount: samples.count,
                    samples: samples
                ),
                options: output
            )
        case .jsonl:
            try CLIOutput.emitJSONLines(
                samples.map {
                    SampleLinePayload(
                        evaluationID: artifact.evaluationID,
                        resultID: artifact.resultID,
                        sample: $0
                    )
                }
            )
        case .rawJSON:
            preconditionFailure("Validated output format is exhaustive.")
        }
    }

    private func matches(_ sample: EvaluationSample) -> Bool {
        if onlyFailures, !sample.hasFailure {
            return false
        }
        if let metric, !sample.metrics.contains(where: { $0.name == metric }) {
            return false
        }
        if let kind, !sample.metrics.contains(where: { $0.kind == kind }) {
            return false
        }
        if let evaluatorKind {
            let containsEvaluator = sample.metrics.contains(where: {
                $0.evaluatorKind == evaluatorKind
            })
            if !containsEvaluator {
                return false
            }
        }
        if let promptContains {
            let promptMatches =
                sample.prompt?.localizedCaseInsensitiveContains(
                    promptContains
                ) == true
            if !promptMatches {
                return false
            }
        }
        if let rationaleContains {
            let containsRationale = sample.metrics.contains(where: {
                $0.rationale?.localizedCaseInsensitiveContains(
                    rationaleContains
                ) == true
            })
            if !containsRationale {
                return false
            }
        }
        return true
    }

    private func printSamples(_ samples: [EvaluationSample]) {
        if samples.isEmpty {
            print("No matching evaluation samples.")
        }
        for sample in samples {
            let failed = sample.metrics.filter(\.failed).map(\.name)
            let status =
                failed.isEmpty
                ? "no failing metrics"
                : "failed \(failed.joined(separator: ", "))"
            print("Sample \(sample.index): \(status)")
        }
    }
}

private func printArtifactSummary(_ artifact: EvaluationArtifact) {
    print("Evaluation: \(artifact.evaluationID ?? "unknown")")
    print("Result ID: \(artifact.resultID ?? "unknown")")
    print("Samples: \(artifact.samples.count)")
    if let duration = artifact.durationInMilliseconds {
        print("Duration: \(formattedNumber(duration)) ms")
    }
    if !artifact.evaluationInfo.isEmpty {
        print("\nInfo:")
        for key in artifact.evaluationInfo.keys.sorted() {
            guard let value = artifact.evaluationInfo[key] else { continue }
            print("- \(key): \(textValue(value))")
        }
    }
    print("\nSummary:")
    if artifact.summaries.isEmpty {
        print("- No aggregate metrics.")
    }
    for metric in artifact.summaries {
        let value = metric.value.map(formattedNumber) ?? "non-numeric"
        let group = metric.group.map { " [\($0)]" } ?? ""
        print("- \(metric.name): \(value)\(group)")
    }
}

private func textValue(_ value: JSONValue) -> String {
    switch value {
    case .null:
        "null"
    case .bool(let value):
        String(value)
    case .integer(let value):
        String(value)
    case .number(let value):
        formattedNumber(value)
    case .string(let value):
        value
    case .array, .object:
        "(structured JSON)"
    }
}
