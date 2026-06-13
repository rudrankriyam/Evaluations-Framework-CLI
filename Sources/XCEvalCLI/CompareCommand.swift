import ArgumentParser
import XCEvalCore

struct CompareCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compare",
        abstract: "Compare aggregate metrics from two evaluation artifacts.",
        discussion: """
            Deltas are candidate minus baseline. xceval does not assume whether a \
            higher or lower value is better because metric direction is \
            evaluation-specific.
            """
    )

    @Argument(help: "Baseline .xcevalresult path.")
    var baselinePath: String

    @Argument(help: "Candidate .xcevalresult path.")
    var candidatePath: String

    @OptionGroup var outputOptions: StandardOutputOptions

    mutating func run() throws {
        let output = try outputOptions.resolve()
        let baseline = try EvaluationArtifact(
            contentsOf: expandedURL(baselinePath)
        )
        let candidate = try EvaluationArtifact(
            contentsOf: expandedURL(candidatePath)
        )
        let comparisons = baseline.comparisons(with: candidate)

        switch output.format {
        case .text:
            printComparisons(
                comparisons,
                baselinePath: baseline.sourceURL.path,
                candidatePath: candidate.sourceURL.path
            )
        case .json:
            try CLIOutput.emit(
                ComparePayload(
                    baseline: ArtifactIdentity(baseline),
                    candidate: ArtifactIdentity(candidate),
                    metrics: comparisons
                ),
                options: output
            )
        case .jsonl, .rawJSON:
            preconditionFailure("Validated output format is exhaustive.")
        }
    }

    private func printComparisons(
        _ comparisons: [EvaluationMetricComparison],
        baselinePath: String,
        candidatePath: String
    ) {
        print("Baseline: \(baselinePath)")
        print("Candidate: \(candidatePath)")
        print()
        for comparison in comparisons {
            let baselineValue = comparison.baseline.map(formattedNumber) ?? "missing"
            let candidateValue = comparison.candidate.map(formattedNumber) ?? "missing"
            let delta =
                comparison.delta.map {
                    $0 >= 0 ? "+\(formattedNumber($0))" : formattedNumber($0)
                } ?? "n/a"
            print(
                "\(comparison.name): \(baselineValue) -> "
                    + "\(candidateValue) (delta \(delta))"
            )
        }
    }
}
