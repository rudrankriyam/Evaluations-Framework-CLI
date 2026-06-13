import ArgumentParser
import Foundation
import XCEvalCore

struct PipelineCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pipeline",
        abstract: "Run a complete, versioned evaluation pipeline.",
        discussion: """
            A pipeline manifest can invoke typed evaluation producers, select \
            one new result, validate it, and write normalized inspection, report, \
            metrics, failures, datasets, comparisons, and gate results into one \
            artifact directory.
            """
    )

    @Argument(
        help: "Pipeline manifest. Defaults to xceval.pipeline.json."
    )
    var manifestPath = "xceval.pipeline.json"

    @Option(
        name: .customLong("set"),
        help: """
            Set a ${NAME} variable used in manifest paths, stages, and \
            environment values. Repeat as --set NAME=value.
            """
    )
    var assignments: [String] = []

    @Option(
        name: .long,
        help: "Override the manifest's Xcode.app or Contents/Developer path."
    )
    var xcode: String?

    @Flag(
        name: .long,
        help: "Replace the pipeline artifact directory if it already exists."
    )
    var force = false

    @Flag(
        name: .long,
        help: "Analyze matching existing results even if no stage changed them."
    )
    var includeExisting = false

    @OptionGroup var outputOptions: StandardOutputOptions

    mutating func run() throws {
        let output = try outputOptions.resolve()
        let manifestURL = expandedURL(manifestPath)
        let configuration = try loadConfiguration(from: manifestURL)
        let variables = try pipelineVariables(assignments)
        let context = try PipelineContext(
            configuration: configuration,
            manifestURL: manifestURL,
            variables: variables,
            xcodeOverride: xcode
        )

        try prepareArtifactsDirectory(context.artifactsDirectory)
        let before = artifactSnapshot(at: context.resultsPath)
        let steps = try runSteps(context)
        if let failed = steps.first(where: { $0.status != 0 }) {
            let error = "Step '\(failed.name)' exited with status \(failed.status)."
            let payload = PipelinePayload(
                name: context.name,
                manifestPath: manifestURL.path,
                workingDirectory: context.workingDirectory.path,
                resultsPath: context.resultsPath.path,
                artifactsDirectory: context.artifactsDirectory.path,
                xcode: context.xcode,
                steps: steps,
                artifact: nil,
                validation: nil,
                gates: [],
                aggregateComparison: [],
                outputs: [:],
                passed: false,
                errors: [error]
            )
            try writePipelinePayload(payload, context: context)
            try emit(payload, output: output)
            throw ExitCode(failed.status)
        }

        let artifacts = try producedArtifacts(
            context: context,
            before: before
        )
        let artifact = try selectedArtifact(
            from: artifacts,
            selection: configuration.selection
        )
        let analysis = try writeAnalysis(
            artifact: artifact,
            baselinePath: context.baselinePath,
            gates: configuration.gates,
            context: context
        )
        var errors: [String] = []
        if !analysis.validation.valid {
            errors.append(
                "Artifact validation found "
                    + "\(analysis.validation.errorCount) error(s)."
            )
        }
        if let gateError = analysis.gateError {
            errors.append(gateError)
        } else if !analysis.gates.allSatisfy(\.passed) {
            errors.append("One or more evaluation gates failed.")
        }

        let payload = PipelinePayload(
            name: context.name,
            manifestPath: manifestURL.path,
            workingDirectory: context.workingDirectory.path,
            resultsPath: context.resultsPath.path,
            artifactsDirectory: context.artifactsDirectory.path,
            xcode: context.xcode,
            steps: steps,
            artifact: ArtifactIdentity(artifact),
            validation: analysis.validation,
            gates: analysis.gates,
            aggregateComparison: analysis.aggregateComparison,
            outputs: analysis.outputs,
            passed: errors.isEmpty,
            errors: errors
        )
        try writePipelinePayload(payload, context: context)
        try emit(payload, output: output)

        if !payload.passed {
            throw ExitCode.failure
        }
    }

    private func loadConfiguration(
        from url: URL
    ) throws -> EvaluationPipelineConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ValidationError(
                "The pipeline manifest does not exist: \(url.path)"
            )
        }
        let configuration = try JSONDecoder().decode(
            EvaluationPipelineConfiguration.self,
            from: Data(contentsOf: url)
        )
        try configuration.validate()
        return configuration
    }

    private func prepareArtifactsDirectory(_ url: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            guard force else {
                throw ValidationError(
                    """
                    Pipeline artifacts already exist at \(url.path). Pass \
                    --force to replace them.
                    """
                )
            }
            try fileManager.removeItem(at: url)
        }
        try fileManager.createDirectory(
            at: url.appendingPathComponent("logs"),
            withIntermediateDirectories: true
        )
    }

    private func runSteps(
        _ context: PipelineContext
    ) throws -> [PipelineStepPayload] {
        var payloads: [PipelineStepPayload] = []
        for (index, step) in context.steps.enumerated() {
            var environment = context.environment
            environment.merge(step.environment) { _, new in new }
            let result = try ProcessRunner.run(
                executable: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: step.command,
                currentDirectory: context.workingDirectory,
                environment: environment
            )
            let prefix =
                String(format: "%02d", index + 1)
                + "-"
                + sanitizedFileComponent(step.name)
            let stdout = context.artifactsDirectory
                .appendingPathComponent("logs/\(prefix).stdout.log")
            let stderr = context.artifactsDirectory
                .appendingPathComponent("logs/\(prefix).stderr.log")
            try result.standardOutput.write(to: stdout, options: .atomic)
            try result.standardError.write(to: stderr, options: .atomic)
            payloads.append(
                PipelineStepPayload(
                    name: step.name,
                    command: step.command,
                    status: result.status,
                    standardOutputPath: stdout.path,
                    standardErrorPath: stderr.path
                )
            )
            if result.status != 0 {
                break
            }
        }
        return payloads
    }

    private func producedArtifacts(
        context: PipelineContext,
        before: [String: ArtifactStamp]
    ) throws -> [EvaluationArtifact] {
        let after = artifactSnapshot(at: context.resultsPath)
        let includeAll = includeExisting || context.steps.isEmpty
        let paths = after.keys.filter {
            includeAll || before[$0] != after[$0]
        }.sorted()
        let artifacts = try paths.flatMap { path in
            let loaded = try EvaluationArtifactLoader.load(
                from: URL(fileURLWithPath: path)
            )
            if includeAll {
                return loaded
            }
            return artifactsAddedOrChanged(
                loaded,
                comparedTo: before[path]
            )
        }
        guard !artifacts.isEmpty else {
            throw ValidationError(
                """
                Pipeline stages succeeded but no new or changed evaluation \
                artifacts were found under \(context.resultsPath.path). Use \
                --include-existing to analyze an existing result.
                """
            )
        }
        return artifacts
    }

    private func selectedArtifact(
        from artifacts: [EvaluationArtifact],
        selection: EvaluationPipelineSelection?
    ) throws -> EvaluationArtifact {
        let selected = artifacts.filter { artifact in
            (selection?.evaluationID == nil
                || artifact.evaluationID == selection?.evaluationID)
                && (selection?.resultID == nil
                    || artifact.resultID == selection?.resultID)
        }
        guard !selected.isEmpty else {
            throw ValidationError(
                "No produced artifact matches the pipeline selection."
            )
        }
        guard selected.count == 1 else {
            throw ValidationError(
                """
                Pipeline resolved to \(selected.count) artifacts. Add selection \
                with evaluationID or resultID to the manifest.
                """
            )
        }
        return selected[0]
    }

    private func writeAnalysis(
        artifact: EvaluationArtifact,
        baselinePath: URL?,
        gates: [String],
        context: PipelineContext
    ) throws -> PipelineAnalysis {
        var outputs: [String: String] = [:]
        let result = context.artifactsDirectory
            .appendingPathComponent("result.xcevalresult")
        try JSONValue.object(artifact.root)
            .encodedData(pretty: true)
            .write(to: result, options: .atomic)
        outputs["result"] = result.path

        let inspect = context.artifactsDirectory
            .appendingPathComponent("inspect.json")
        try writeJSON(
            InspectPayload(
                artifact: ArtifactPayload(
                    artifact: artifact,
                    includeSamples: true
                )
            ),
            to: inspect
        )
        outputs["inspect"] = inspect.path

        let baseline = try baselinePath.map {
            try loadSingleArtifact(path: $0.path)
        }
        let report = context.artifactsDirectory
            .appendingPathComponent("report.json")
        try writeJSON(
            ReportPayload(artifact: artifact, baseline: baseline),
            to: report
        )
        outputs["report"] = report.path

        let metrics = context.artifactsDirectory
            .appendingPathComponent("metrics.json")
        try writeJSON(MetricsPayload(artifact: artifact), to: metrics)
        outputs["metrics"] = metrics.path

        let failures = context.artifactsDirectory
            .appendingPathComponent("failures.jsonl")
        try writeJSONLines(
            artifact.samples.filter(\.hasFailure).map {
                SampleLinePayload(
                    evaluationID: artifact.evaluationID,
                    resultID: artifact.resultID,
                    sample: $0
                )
            },
            to: failures
        )
        outputs["failures"] = failures.path

        let dataset = context.artifactsDirectory
            .appendingPathComponent("dataset.json")
        try writeJSON(DatasetPayload(artifact: artifact), to: dataset)
        outputs["dataset"] = dataset.path

        let promptResponse = context.artifactsDirectory
            .appendingPathComponent("prompt-response.json")
        try writeJSON(artifact.datasetPairs, to: promptResponse)
        outputs["promptResponse"] = promptResponse.path

        let validationPayload = ArtifactValidationPayload(artifact)
        let validation = context.artifactsDirectory
            .appendingPathComponent("validation.json")
        try writeJSON(validationPayload, to: validation)
        outputs["validation"] = validation.path

        let comparison = baseline?.comparisons(with: artifact) ?? []
        if let baseline {
            let comparisonURL = context.artifactsDirectory
                .appendingPathComponent("comparison.json")
            try writeJSON(
                ComparePayload(
                    baseline: ArtifactIdentity(baseline),
                    candidate: ArtifactIdentity(artifact),
                    metrics: comparison
                ),
                to: comparisonURL
            )
            outputs["comparison"] = comparisonURL.path
        }

        var gateResults: [EvaluationGateResult] = []
        var gateError: String?
        if !gates.isEmpty {
            do {
                gateResults = try gates.map {
                    try EvaluationGateRule($0).evaluate(in: artifact)
                }
                let gateURL = context.artifactsDirectory
                    .appendingPathComponent("gates.json")
                try writeJSON(
                    GatePayload(
                        artifact: artifact,
                        results: gateResults
                    ),
                    to: gateURL
                )
                outputs["gates"] = gateURL.path
            } catch {
                gateError = error.localizedDescription
                let gateURL = context.artifactsDirectory
                    .appendingPathComponent("gates.json")
                try writeJSON(
                    PipelineGateErrorPayload(
                        rules: gates,
                        error: error.localizedDescription
                    ),
                    to: gateURL
                )
                outputs["gates"] = gateURL.path
            }
        }

        return PipelineAnalysis(
            validation: validationPayload,
            gates: gateResults,
            gateError: gateError,
            aggregateComparison: comparison,
            outputs: outputs
        )
    }

    private func writePipelinePayload(
        _ payload: PipelinePayload,
        context: PipelineContext
    ) throws {
        try writeJSON(
            payload,
            to: context.artifactsDirectory
                .appendingPathComponent("pipeline-report.json")
        )
    }

    private func emit(
        _ payload: PipelinePayload,
        output: ResolvedOutputOptions
    ) throws {
        switch output.format {
        case .text:
            print("\(payload.passed ? "PASS" : "FAIL") \(payload.name)")
            print("Stages: \(payload.steps.count)")
            if let artifact = payload.artifact {
                print(
                    "Evaluation: \(artifact.evaluationID ?? "unknown") "
                        + "(\(artifact.resultID ?? "unknown"))"
                )
            }
            print("Artifacts: \(payload.artifactsDirectory)")
            for error in payload.errors {
                print("Error: \(error)")
            }
        case .json:
            try CLIOutput.emit(payload, options: output)
        case .jsonl, .rawJSON:
            preconditionFailure("Validated output format is exhaustive.")
        }
    }
}

private struct PipelineAnalysis {
    let validation: ArtifactValidationPayload
    let gates: [EvaluationGateResult]
    let gateError: String?
    let aggregateComparison: [EvaluationMetricComparison]
    let outputs: [String: String]
}

private struct PipelineGateErrorPayload: Encodable {
    let schemaVersion = "xceval.pipeline-report/v1"
    let rules: [String]
    let error: String
}

private struct ResolvedPipelineStep {
    let name: String
    let command: [String]
    let environment: [String: String]
}

private struct PipelineContext {
    let name: String
    let workingDirectory: URL
    let artifactsDirectory: URL
    let resultsPath: URL
    let baselinePath: URL?
    let steps: [ResolvedPipelineStep]
    let environment: [String: String]
    let xcode: XcodeInstallation?

    init(
        configuration: EvaluationPipelineConfiguration,
        manifestURL: URL,
        variables: [String: String],
        xcodeOverride: String?
    ) throws {
        let manifestDirectory = manifestURL.deletingLastPathComponent()
        name = try expandPipelineVariables(
            configuration.name,
            values: variables
        )
        let working = try expandPipelineVariables(
            configuration.workingDirectory,
            values: variables
        )
        let resolvedWorkingDirectory = resolvePipelinePath(
            working,
            relativeTo: manifestDirectory
        )
        workingDirectory = resolvedWorkingDirectory
        artifactsDirectory = resolvePipelinePath(
            try expandPipelineVariables(
                configuration.artifactsDirectory,
                values: variables
            ),
            relativeTo: resolvedWorkingDirectory
        )
        resultsPath = resolvePipelinePath(
            try expandPipelineVariables(
                configuration.resultsPath,
                values: variables
            ),
            relativeTo: resolvedWorkingDirectory
        )
        baselinePath = try configuration.baseline.map {
            resolvePipelinePath(
                try expandPipelineVariables($0, values: variables),
                relativeTo: resolvedWorkingDirectory
            )
        }
        steps = try configuration.steps.map { step in
            ResolvedPipelineStep(
                name: try expandPipelineVariables(
                    step.name,
                    values: variables
                ),
                command: try step.command.map {
                    try expandPipelineVariables($0, values: variables)
                },
                environment: try step.environment.mapValues {
                    try expandPipelineVariables($0, values: variables)
                }
            )
        }

        let preferredXcode = try (xcodeOverride ?? configuration.xcode).map {
            try expandPipelineVariables($0, values: variables)
        }
        if configuration.requiresEvaluationsXcode || preferredXcode != nil {
            let installation = try XcodeLocator.evaluationCapableInstallation(
                preferredPath: preferredXcode
            )
            xcode = installation
            environment = XcodeLocator.environment(for: installation)
        } else {
            xcode = nil
            environment = ProcessInfo.processInfo.environment
        }
    }
}

private func pipelineVariables(
    _ assignments: [String]
) throws -> [String: String] {
    var values = ProcessInfo.processInfo.environment
    for assignment in assignments {
        guard
            let separator = assignment.firstIndex(of: "="),
            separator != assignment.startIndex
        else {
            throw ValidationError(
                "Invalid --set '\(assignment)'. Expected NAME=value."
            )
        }
        let name = String(assignment[..<separator])
        guard
            name.range(
                of: #"^[A-Za-z_][A-Za-z0-9_]*$"#,
                options: .regularExpression
            ) != nil
        else {
            throw ValidationError(
                """
                Invalid --set name '\(name)'. Use letters, numbers, and \
                underscores, starting with a letter or underscore.
                """
            )
        }
        let value = String(assignment[assignment.index(after: separator)...])
        values[name] = value
    }
    return values
}

private func expandPipelineVariables(
    _ value: String,
    values: [String: String]
) throws -> String {
    let expression = try NSRegularExpression(
        pattern: #"\$\{([A-Za-z_][A-Za-z0-9_]*)\}"#
    )
    var result = value
    let matches = expression.matches(
        in: value,
        range: NSRange(value.startIndex..., in: value)
    )
    for match in matches.reversed() {
        guard
            let nameRange = Range(match.range(at: 1), in: value),
            let fullRange = Range(match.range(at: 0), in: result)
        else {
            continue
        }
        let name = String(value[nameRange])
        guard let replacement = values[name] else {
            throw ValidationError(
                "Pipeline variable '${\(name)}' is not set."
            )
        }
        result.replaceSubrange(fullRange, with: replacement)
    }
    return result
}

private func resolvePipelinePath(
    _ path: String,
    relativeTo base: URL
) -> URL {
    let expanded = (path as NSString).expandingTildeInPath
    if (expanded as NSString).isAbsolutePath {
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }
    return base.appendingPathComponent(expanded).standardizedFileURL
}

private func writeJSON<T: Encodable>(
    _ value: T,
    to url: URL
) throws {
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

private func writeJSONLines<T: Encodable>(
    _ values: [T],
    to url: URL
) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var data = Data()
    for value in values {
        data.append(try encoder.encode(value))
        data.append(0x0A)
    }
    try data.write(to: url, options: .atomic)
}
