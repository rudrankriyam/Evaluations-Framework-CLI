import ArgumentParser
import Foundation
import XCEvalCore

struct PlanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plan",
        abstract: "Plan a unique run directory and provenance record without writing.",
        discussion: """
            Planning checks that the proposed directory is currently unused but \
            does not reserve it. The eventual creator must revalidate and create \
            the run directory exclusively.
            """
    )

    @Option(
        name: .long,
        help: "Unique run identifier. Defaults to a generated identifier."
    )
    var runID: String?

    @Option(
        name: .long,
        help: "Parent directory for immutable run directories."
    )
    var runsRoot = ".xceval/runs"

    @Option(
        name: .long,
        help: "Path that the planned run must not contain. Repeatable."
    )
    var protect: [String] = []

    @Option(
        name: .long,
        help: """
            Include one non-sensitive environment value in provenance. \
            Secret-like names always remain presence-only. Repeatable.
            """
    )
    var revealEnvironment: [String] = []

    @OptionGroup var outputOptions: StandardOutputOptions

    mutating func run() throws {
        let output = try outputOptions.resolve()
        let payload = try makePayload()

        switch output.format {
        case .text:
            print("Planned evaluation run \(payload.run.runID).")
            print("Run directory: \(payload.run.runDirectory.path)")
            print("Artifacts: \(payload.run.artifactsDirectory.path)")
            print("Logs: \(payload.run.logsDirectory.path)")
            print("Provenance: \(payload.run.provenanceFile.path)")
            print("Events: \(payload.run.eventsFile.path)")
            print()
            print("Required provenance evidence:")
            for field in payload.provenance.requiredEvidence {
                print("- \(field)")
            }
            print()
            print("No directories or files were created.")
            print("The run identifier was not reserved.")
        case .json:
            try CLIOutput.emit(payload, options: output)
        case .jsonl, .rawJSON:
            preconditionFailure("Validated output format is exhaustive.")
        }
    }

    func makePayload(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> EvaluationPlanPayload {
        let identifier =
            runID ?? "run-\(UUID().uuidString.lowercased())"
        let currentDirectory = URL(
            fileURLWithPath: fileManager.currentDirectoryPath,
            isDirectory: true
        ).standardizedFileURL
        let plan = try EvaluationRunDirectoryPlan.plan(
            runID: identifier,
            runsRoot: expandedURL(runsRoot),
            protectedPaths: [currentDirectory] + protect.map(expandedURL),
            fileManager: fileManager
        )
        return EvaluationPlanPayload(
            run: plan,
            provenance: EvaluationProvenanceScaffold(
                runID: identifier,
                createdAt: now,
                environment: RedactedEnvironmentDescriptor(
                    environment: environment,
                    revealValuesFor: Set(revealEnvironment)
                )
            )
        )
    }
}

struct EvaluationPlanPayload: Encodable {
    let schemaVersion = "xceval.plan/v1"
    let command = "plan"
    let readOnly = true
    let reserved = false
    let run: EvaluationRunDirectoryPlan
    let provenance: EvaluationProvenanceScaffold
}

struct EvaluationProvenanceScaffold: Encodable {
    let schemaVersion = EvaluationProvenanceManifest.currentSchemaVersion
    let runID: String
    let createdAt: String
    let integrity: EvaluationIntegrityDigests? = nil
    let git: GitProvenanceEvidence? = nil
    let toolchain: ToolchainProvenanceEvidence? = nil
    let environment: RedactedEnvironmentDescriptor
    let mutations: [ProvenanceMutation] = []
    let artifacts: [ProvenanceArtifact] = []
    let requiredEvidence = [
        "integrity.subject",
        "integrity.evaluationContract",
        "integrity.execution",
        "git.baseCommit",
        "git.tree",
        "toolchain.xcevalVersion",
        "toolchain.xcevalBinary"
    ]

    init(
        runID: String,
        createdAt: Date,
        environment: RedactedEnvironmentDescriptor
    ) {
        self.runID = runID
        self.createdAt = createdAt.ISO8601Format()
        self.environment = environment
    }
}
