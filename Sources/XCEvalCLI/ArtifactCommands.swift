import ArgumentParser
import XCEvalCore

struct InspectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Read metadata, aggregate metrics, and sample rows."
    )

    @Argument(help: "Path to a .xcevalresult JSON artifact.")
    var path: String

    @Flag(
        name: .long,
        help: "Omit per-sample rows from normalized JSON output."
    )
    var summaryOnly = false

    @OptionGroup var outputOptions: InspectOutputOptions

    mutating func run() throws {
        let output = try outputOptions.resolve()
        let artifact = try EvaluationArtifact(contentsOf: expandedURL(path))

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

    @Argument(help: "Path to a .xcevalresult JSON artifact.")
    var path: String

    @Flag(
        name: .long,
        help: "Emit only samples containing a failing metric."
    )
    var onlyFailures = false

    @OptionGroup var outputOptions: SamplesOutputOptions

    mutating func run() throws {
        let output = try outputOptions.resolve()
        let artifact = try EvaluationArtifact(contentsOf: expandedURL(path))
        let samples =
            onlyFailures
            ? artifact.samples.filter(\.hasFailure)
            : artifact.samples

        switch output.format {
        case .text:
            printSamples(samples)
        case .json:
            try CLIOutput.emit(
                SamplesPayload(
                    path: artifact.sourceURL.path,
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
