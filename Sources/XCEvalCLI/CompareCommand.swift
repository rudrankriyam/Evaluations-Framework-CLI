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

    @Flag(
        name: .long,
        help: "Include matched per-sample regressions and changes."
    )
    var includeSamples = false

    @Option(
        name: .long,
        help: """
            RFC 6901 JSON Pointer inside each normalized sample input used as \
            cross-run identity. Without this option, --include-samples uses a \
            canonical digest of the complete input.
            """
    )
    var sampleKey: String?

    @Flag(
        name: .long,
        help: "Treat Subject-versus-Expected structural differences as failures."
    )
    var includeStructuralDifferences = false

    @OptionGroup var outputOptions: StandardOutputOptions

    mutating func run() throws {
        if sampleKey != nil, !includeSamples {
            throw ValidationError("--sample-key requires --include-samples.")
        }
        if includeStructuralDifferences, !includeSamples {
            throw ValidationError(
                "--include-structural-differences requires --include-samples."
            )
        }
        let output = try outputOptions.resolve()
        let baseline = try loadSingleArtifact(path: baselinePath)
        let candidate = try loadSingleArtifact(path: candidatePath)
        let comparisons = baseline.comparisons(with: candidate)
        let keyStrategy: EvaluationSampleKeyStrategy? =
            includeSamples
            ? sampleKey.map(EvaluationSampleKeyStrategy.jsonPointer)
                ?? .canonicalInputDigest
            : nil
        let sampleComparisons = keyStrategy.map {
            baseline.sampleComparisons(
                with: candidate,
                keyStrategy: $0,
                includingStructuralDifferences: includeStructuralDifferences
            )
        }

        switch output.format {
        case .text:
            printComparisons(
                comparisons,
                baselinePath: baseline.sourceURL.path,
                candidatePath: candidate.sourceURL.path
            )
            if let sampleComparisons {
                printSampleComparisons(sampleComparisons)
            }
        case .json:
            try CLIOutput.emit(
                ComparePayload(
                    baseline: ArtifactIdentity(baseline),
                    candidate: ArtifactIdentity(candidate),
                    metrics: comparisons,
                    sampleKeyStrategy: keyStrategy,
                    samples: sampleComparisons
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
            var label = comparison.name
            if let group = comparison.group {
                label += " [\(group)]"
            }
            if comparison.occurrence > 1 {
                label += " #\(comparison.occurrence)"
            }
            let baselineValue = comparison.baseline.map(formattedNumber) ?? "missing"
            let candidateValue = comparison.candidate.map(formattedNumber) ?? "missing"
            let delta =
                comparison.delta.map {
                    $0 >= 0 ? "+\(formattedNumber($0))" : formattedNumber($0)
                } ?? "n/a"
            print(
                "\(label): \(baselineValue) -> "
                    + "\(candidateValue) (delta \(delta))"
            )
        }
    }

    private func printSampleComparisons(
        _ comparisons: [EvaluationSampleComparison]
    ) {
        print()
        print("Sample changes: \(comparisons.count)")
        for classification in EvaluationSampleComparisonClassification.allCases {
            let count = comparisons.count {
                $0.classification == classification
            }
            if count > 0 {
                print("- \(classification.rawValue): \(count)")
            }
        }
    }
}
