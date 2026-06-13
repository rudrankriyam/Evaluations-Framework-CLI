import ArgumentParser
import Foundation
import XCEvalCore

struct CapabilitiesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capabilities",
        abstract: "Describe every Evaluations workflow and xceval boundary."
    )

    @Option(
        name: .long,
        help: "Xcode.app or Contents/Developer path to include in discovery."
    )
    var xcode: String?

    @OptionGroup var outputOptions: StandardOutputOptions

    mutating func run() throws {
        let output = try outputOptions.resolve()
        let installation = XcodeLocator.installations(
            preferredPath: xcode
        ).first(where: {
            $0.exportsEvaluations && $0.macOSEvaluationsFramework != nil
        })
        let payload = CapabilitiesPayload(selectedXcode: installation)

        switch output.format {
        case .text:
            print(
                "xceval is an unofficial community CLI. It is not an Apple product."
            )
            for capability in payload.capabilities {
                print(
                    "- \(capability.name): \(capability.support.rawValue)"
                        + " [\(capability.command)]"
                )
            }
        case .json:
            try CLIOutput.emit(payload, options: output)
        case .jsonl, .rawJSON:
            preconditionFailure("Validated output format is exhaustive.")
        }
    }
}

struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List results in an artifact, JSONL collection, or directory."
    )

    @Argument(
        help: "Artifact, .xcevalresults.jsonl, directory, or '-' for stdin."
    )
    var path: String

    @OptionGroup var selection: ArtifactSelectionOptions
    @OptionGroup var outputOptions: StandardOutputOptions

    mutating func run() throws {
        let output = try outputOptions.resolve()
        let artifacts = try loadSelectedArtifacts(
            path: path,
            selection: selection
        )
        let payload = ListPayload(artifacts: artifacts)

        switch output.format {
        case .text:
            for artifact in artifacts {
                print(
                    "\(artifact.evaluationID ?? "unknown") "
                        + "\(artifact.resultID ?? "unknown") "
                        + "samples=\(artifact.samples.count) "
                        + "summary=\(artifact.summaries.count) "
                        + "source=\(artifact.sourceDescription)"
                )
            }
        case .json:
            try CLIOutput.emit(payload, options: output)
        case .jsonl, .rawJSON:
            preconditionFailure("Validated output format is exhaustive.")
        }
    }
}

struct ValidateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Validate result structure without rejecting unknown fields."
    )

    @Argument(
        help: "Artifact, .xcevalresults.jsonl, directory, or '-' for stdin."
    )
    var path: String

    @OptionGroup var selection: ArtifactSelectionOptions
    @Flag(
        name: .long,
        help: "Treat validation warnings as a failing exit status."
    )
    var strict = false

    @OptionGroup var outputOptions: StandardOutputOptions

    mutating func run() throws {
        let output = try outputOptions.resolve()
        let artifacts: [EvaluationArtifact]
        do {
            artifacts = try loadSelectedArtifacts(
                path: path,
                selection: selection
            )
        } catch {
            let payload = ValidationPayload(loadError: error.localizedDescription)
            try emit(payload, output: output)
            throw ExitCode.failure
        }

        let payload = ValidationPayload(artifacts: artifacts)
        try emit(payload, output: output)
        if !payload.valid || (strict && payload.warningCount > 0) {
            throw ExitCode.failure
        }
    }

    private func emit(
        _ payload: ValidationPayload,
        output: ResolvedOutputOptions
    ) throws {
        switch output.format {
        case .text:
            print(
                payload.valid
                    ? "Valid evaluation input."
                    : "Invalid evaluation input."
            )
            print(
                "Artifacts: \(payload.artifacts.count), "
                    + "errors: \(payload.errorCount), "
                    + "warnings: \(payload.warningCount)"
            )
            for artifact in payload.artifacts {
                for issue in artifact.issues {
                    print(
                        "- \(issue.severity.rawValue): "
                            + "\(issue.code): \(issue.message)"
                    )
                }
            }
            if let loadError = payload.loadError {
                print("- error: \(loadError)")
            }
        case .json:
            try CLIOutput.emit(payload, options: output)
        case .jsonl, .rawJSON:
            preconditionFailure("Validated output format is exhaustive.")
        }
    }
}
