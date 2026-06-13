import ArgumentParser
import XCEvalCore

struct ReportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "report",
        abstract: "Emit the machine-readable data behind Xcode's evaluation report.",
        discussion: """
            The report combines aggregate operations, exact per-metric numeric \
            values, pass/fail counts, complete sample rows, evaluator rationales, \
            and structural Subject-versus-Expected issues. Add --baseline to \
            include aggregate run comparisons.
            """
    )

    @Argument(
        help: "Artifact, .xcevalresults.jsonl, directory, or '-' for stdin."
    )
    var path: String

    @Option(
        name: .long,
        help: "Optional baseline artifact for aggregate comparison."
    )
    var baseline: String?

    @OptionGroup var selection: ArtifactSelectionOptions
    @OptionGroup var outputOptions: StandardOutputOptions

    mutating func run() throws {
        let output = try outputOptions.resolve()
        let artifact = try loadSingleArtifact(
            path: path,
            selection: selection
        )
        let baselineArtifact = try baseline.map(loadSingleArtifact)
        let payload = ReportPayload(
            artifact: artifact,
            baseline: baselineArtifact
        )

        switch output.format {
        case .text:
            print("Evaluation: \(artifact.evaluationID ?? "unknown")")
            print("Samples: \(artifact.samples.count)")
            print("Metrics: \(artifact.metricProfiles.count)")
            print(
                "Failing samples: "
                    + "\(artifact.samples.count(where: \.hasFailure))"
            )
            let issueCount = artifact.samples.reduce(0) {
                $0 + $1.subjectExpectedDifferences.count
            }
            print("Subject/expected issues: \(issueCount)")
            if let baselineArtifact {
                print(
                    "Baseline: "
                        + "\(baselineArtifact.evaluationID ?? "unknown") "
                        + "(\(baselineArtifact.resultID ?? "unknown"))"
                )
            }
        case .json:
            try CLIOutput.emit(payload, options: output)
        case .jsonl, .rawJSON:
            preconditionFailure("Validated output format is exhaustive.")
        }
    }
}
