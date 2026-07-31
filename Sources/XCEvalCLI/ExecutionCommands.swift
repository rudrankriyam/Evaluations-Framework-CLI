import ArgumentParser
import Foundation
import XCEvalCore

struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run any typed evaluation producer and collect its artifacts.",
        discussion: """
            The command after '--' remains responsible for importing \
            Evaluations.framework and saving .xcevalresult files. xceval records \
            the process result and returns every new or changed artifact.
            """
    )

    @Argument(
        help: """
            Declared target ID. Omit it when providing a legacy producer \
            command after '--'.
            """
    )
    var targetID: String?

    @Option(
        name: .long,
        help: """
            Single results path for a legacy producer, or an explicit override \
            of a declared target's evaluation outputs.
            """
    )
    var resultsPath: String?

    @Option(
        name: .customLong("targets"),
        help: "Target manifest. Defaults to .xceval/targets.json."
    )
    var targetManifestPath = ".xceval/targets.json"

    @Option(
        name: .long,
        help: "Working directory for the producer command."
    )
    var workingDirectory: String?

    @Flag(
        name: .long,
        help: "Return all artifacts, including files unchanged by this run."
    )
    var includeExisting = false

    @Flag(
        name: .long,
        help: "Do not fail when the command produces no evaluation artifacts."
    )
    var allowEmpty = false

    @Option(
        name: .long,
        help: "Caller-stable idempotency key for a durable operation receipt."
    )
    var operationID: String?

    @Option(
        name: .long,
        help: "Directory containing durable operation receipts and logs."
    )
    var stateDirectory = ".xceval/operations"

    @Option(
        name: .long,
        help: "Maximum producer wall-clock duration in seconds."
    )
    var timeout: Double?

    @Option(
        name: .long,
        help: "Producer-owned selected-sample manifest."
    )
    var selection: String?

    @OptionGroup var outputOptions: StandardOutputOptions

    @Argument(
        parsing: .postTerminator,
        help: "Producer command and arguments, written after '--'."
    )
    var producerCommand: [String] = []

    mutating func run() async throws {
        if let timeout, !timeout.isFinite || timeout < 0 {
            throw ValidationError("--timeout must be a finite nonnegative value.")
        }
        let output = try outputOptions.resolve()
        let invocation = try resolvedInvocation()
        let operation = try claimOperation(
            invocation: invocation,
            output: output
        )
        if case .existing(let receipt) = operation {
            try emitReplay(
                receipt,
                invocation: invocation,
                output: output
            )
            if receipt.state != .succeeded {
                throw ExitCode.failure
            }
            return
        }
        let runningReceipt: OperationReceipt?
        let operationLease: OperationReceiptLease?
        if case .claimed(let receipt, let lease) = operation {
            runningReceipt = receipt
            operationLease = lease
        } else {
            runningReceipt = nil
            operationLease = nil
        }
        defer { operationLease?.release() }

        let before = invocation.outputs.map {
            artifactSnapshot(at: $0.url)
        }
        let process: ProcessResult
        do {
            process = try await ProcessRunner.runAsync(
                executable: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: invocation.command,
                currentDirectory: invocation.workingDirectory,
                environment: invocation.environment,
                options: processOptions(for: runningReceipt)
            )
        } catch {
            try failOperation(runningReceipt, message: error.localizedDescription)
            throw error
        }
        do {
            try operationLease?.markExecutionFinished()
        } catch {
            try failOperation(
                runningReceipt,
                process: process,
                message: error.localizedDescription
            )
            throw error
        }

        let artifactsByOutput: [[EvaluationArtifact]]
        do {
            artifactsByOutput = try invocation.outputs.enumerated().map {
                index, output in
                let after = artifactSnapshot(at: output.url)
                let changedPaths = after.keys.filter {
                    includeExisting || before[index][$0] != after[$0]
                }.sorted()
                return try changedPaths.flatMap {
                    let loaded = try EvaluationArtifactLoader.load(
                        from: URL(fileURLWithPath: $0)
                    )
                    if includeExisting {
                        return loaded
                    }
                    return artifactsAddedOrChanged(
                        loaded,
                        comparedTo: before[index][$0]
                    )
                }
            }
        } catch {
            try failOperation(
                runningReceipt,
                process: process,
                message: error.localizedDescription
            )
            throw error
        }
        var seenArtifacts = Set<String>()
        let artifacts = artifactsByOutput.flatMap { $0 }.filter {
            seenArtifacts.insert($0.sourceDescription).inserted
        }.sorted {
            if $0.sourceURL.path == $1.sourceURL.path {
                return ($0.sourceLine ?? 0) < ($1.sourceLine ?? 0)
            }
            return $0.sourceURL.path < $1.sourceURL.path
        }
        let artifactError = minimumArtifactError(
            invocation.outputs,
            artifactsByOutput: artifactsByOutput,
            process: process
        )

        let completedReceipt = try completeOperation(
            runningReceipt,
            process: process,
            artifacts: artifacts,
            semanticFailure: artifactError
        )
        let payload = RunPayload(
            producerCommand: invocation.command,
            workingDirectory: invocation.workingDirectory?.path,
            resultsPaths: invocation.outputs.map(\.url.path),
            process: process,
            artifacts: artifacts,
            operationReceipt: completedReceipt,
            errorMessage: artifactError
        )
        try emit(payload, output: output)

        if process.status != 0 {
            throw ExitCode(process.status)
        }
        if let artifactError {
            if output.format == .text {
                FileHandle.standardError.write(Data("\(artifactError)\n".utf8))
            }
            throw ExitCode.failure
        }
    }

    private func resolvedInvocation() throws -> ResolvedRunInvocation {
        if let targetID {
            guard producerCommand.isEmpty else {
                throw ValidationError(
                    "Do not combine a declared target with a command after '--'."
                )
            }
            let loaded = try loadTargetManifest(targetManifestPath)
            let target = try loaded.manifest.target(id: targetID)
            let manifestDirectory = loaded.url.deletingLastPathComponent()
            let resolvedWorkingDirectory =
                workingDirectory.map(expandedURL)
                ?? target.workingDirectory.map {
                    resolvePath($0, relativeTo: manifestDirectory)
                }
                ?? manifestDirectory
            let declaredOutputs = target.outputs.filter {
                $0.format != .xcresult
            }
            guard !declaredOutputs.isEmpty else {
                throw ValidationError(
                    "Target '\(targetID)' has no evaluation-result output."
                )
            }
            let resolvedOutputs: [ResolvedRunOutput]
            if let resultsPath {
                resolvedOutputs = [
                    ResolvedRunOutput(
                        role: declaredOutputs[0].role,
                        url: resolvePath(
                            resultsPath,
                            relativeTo: resolvedWorkingDirectory
                        ),
                        minimumCount: declaredOutputs[0].minimumCount
                    )
                ]
            } else {
                resolvedOutputs = declaredOutputs.map {
                    ResolvedRunOutput(
                        role: $0.role,
                        url: resolvePath(
                            $0.path,
                            relativeTo: resolvedWorkingDirectory
                        ),
                        minimumCount: $0.minimumCount
                    )
                }
            }
            for output in resolvedOutputs {
                try validateRunOutput(output.url)
            }
            var environment = target.resolvedEnvironment()
            if target.argv.first?.contains("/") != true,
                environment["PATH"] == nil
            {
                throw ValidationError(
                    "Target '\(targetID)' must inherit or set PATH because its "
                        + "executable is not an absolute path."
                )
            }
            let resolvedSelection = try selection.map {
                try selectionIdentity(at: $0)
            }
            if let identity = resolvedSelection {
                environment["XCEVAL_SELECTION_PATH"] = identity.path
            }
            if let operationID {
                environment["XCEVAL_OPERATION_ID"] = operationID
            }
            if target.requirements.contains(where: {
                $0.capability == "apple.evaluations"
            }) {
                let installation =
                    try XcodeLocator.evaluationCapableInstallation()
                environment["DEVELOPER_DIR"] =
                    installation.developerDirectory
            }
            return ResolvedRunInvocation(
                command: target.argv,
                workingDirectory: resolvedWorkingDirectory,
                outputs: resolvedOutputs,
                environment: environment,
                targetRevision: target.revision,
                selection: resolvedSelection
            )
        }

        guard !producerCommand.isEmpty else {
            throw ValidationError(
                "Provide a target ID or a producer command after '--'."
            )
        }
        guard let resultsPath else {
            throw ValidationError(
                "Legacy producer commands require --results-path."
            )
        }
        let resolvedWorkingDirectory = workingDirectory.map(expandedURL)
        let resolvedResults = resolvePath(
            resultsPath,
            relativeTo: resolvedWorkingDirectory
                ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        )
        try validateRunOutput(resolvedResults)
        var environment = ProcessInfo.processInfo.environment
        let resolvedSelection = try selection.map {
            try selectionIdentity(at: $0)
        }
        if let identity = resolvedSelection {
            environment["XCEVAL_SELECTION_PATH"] = identity.path
        }
        if let operationID {
            environment["XCEVAL_OPERATION_ID"] = operationID
        }
        return ResolvedRunInvocation(
            command: producerCommand,
            workingDirectory: resolvedWorkingDirectory,
            outputs: [
                ResolvedRunOutput(
                    role: "legacy-results",
                    url: resolvedResults,
                    minimumCount: nil
                )
            ],
            environment: environment,
            targetRevision: nil,
            selection: resolvedSelection
        )
    }

    private func selectionIdentity(at path: String) throws -> RunSelectionIdentity {
        let url = expandedURL(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ValidationError(
                "The selection manifest does not exist: \(url.path)"
            )
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ValidationError(
                "The selection manifest could not be read: "
                    + error.localizedDescription
            )
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ValidationError(
                "The selection manifest is not valid JSON: "
                    + error.localizedDescription
            )
        }
        guard let document = object as? [String: Any] else {
            throw ValidationError(
                "The selection manifest must contain a JSON object."
            )
        }
        guard document["schemaVersion"] as? String == "xceval.selection/v1" else {
            throw ValidationError(
                "The selection manifest must use schemaVersion "
                    + "'xceval.selection/v1'."
            )
        }
        guard
            let sampleKey = document["sampleKey"] as? String,
            !sampleKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let count = document["count"] as? Int,
            count >= 0,
            let samples = document["samples"] as? [Any],
            samples.count == count
        else {
            throw ValidationError(
                "The selection manifest must declare a nonempty sampleKey and "
                    + "a nonnegative count matching its samples array."
            )
        }
        var selectedKeys = Set<String>()
        var canonicalKeys = Set<String>()
        for sample in samples {
            guard
                let value = sample as? [String: Any],
                let key = value["key"] as? String,
                !key.isEmpty,
                let index = value["index"] as? Int,
                index >= 0,
                selectedKeys.insert(key).inserted
            else {
                throw ValidationError(
                    "Every selected sample must contain a unique nonempty key "
                        + "and nonnegative integer index."
                )
            }
            if let rawCanonicalKey = value["canonicalKey"] {
                guard
                    let canonicalKey = rawCanonicalKey as? String,
                    !canonicalKey.isEmpty,
                    canonicalKeys.insert(canonicalKey).inserted
                else {
                    throw ValidationError(
                        "Every selected sample canonicalKey must be a unique "
                            + "nonempty string."
                    )
                }
            }
        }
        let canonical = try JSONSerialization.data(
            withJSONObject: document,
            options: [.sortedKeys]
        )
        let source = document["source"] as? [String: Any]
        return RunSelectionIdentity(
            path: url.path,
            contentDigest: ContentDigest(data: canonical).description,
            sourceArtifactID: source?["artifactID"] as? String
        )
    }

    private func processOptions(
        for receipt: OperationReceipt?
    ) -> ProcessExecutionOptions {
        guard let operationID, let receipt else {
            return ProcessExecutionOptions(
                timeout: timeout,
                handlesInterruptSignals: true
            )
        }
        let root = expandedURL(stateDirectory)
        let digest = ContentDigest(data: Data(operationID.utf8)).rawValue
        let prefix = "\(digest).attempt-\(receipt.attempt)"
        return ProcessExecutionOptions(
            timeout: timeout,
            handlesInterruptSignals: true,
            logs: ProcessLogOptions(
                standardOutputURL:
                    root
                    .appendingPathComponent("logs/\(prefix).stdout.log"),
                standardErrorURL:
                    root
                    .appendingPathComponent("logs/\(prefix).stderr.log"),
                maximumFileBytes: 67_108_864
            )
        )
    }

    private func validateRunOutput(_ output: URL) throws {
        let canonical = output.standardizedFileURL.resolvingSymlinksInPath()
        let home =
            FileManager.default.homeDirectoryForCurrentUser
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard canonical.path != "/", canonical != home else {
            throw DestructivePathError.broadTarget(canonical.path)
        }
    }

    private func claimOperation(
        invocation: ResolvedRunInvocation,
        output: ResolvedOutputOptions
    ) throws -> RunOperationClaim? {
        guard let operationID else { return nil }
        let environmentDigest = try ContentDigest.canonicalJSON(
            invocation.environment
        )
        let digest = try ContentDigest.canonicalJSON(
            RunRequestIdentity(
                command: invocation.command,
                workingDirectory: invocation.workingDirectory?.path,
                resultsPath: invocation.outputs[0].url.path,
                targetRevision: invocation.targetRevision,
                environmentDigest: environmentDigest.description,
                selection: invocation.selection,
                timeout: timeout,
                includeExisting: includeExisting,
                allowEmpty: allowEmpty,
                minimumArtifactCount: invocation.outputs[0].minimumCount
            )
        )
        let receipt = OperationReceipt(
            idempotencyKey: operationID,
            operation: "run",
            inputDigest: digest.description
        )
        let store = OperationReceiptStore(directory: expandedURL(stateDirectory))
        switch try store.claim(receipt) {
        case .claimed(let claimed, let lease):
            return .claimed(claimed, lease)
        case .existing(let existing):
            guard
                existing.operation == "run",
                existing.inputDigest == digest.description
            else {
                throw XCEvalCLIError.operationConflict(
                    operationID: operationID
                )
            }
            _ = output
            return .existing(existing)
        }
    }

    private func completeOperation(
        _ receipt: OperationReceipt?,
        process: ProcessResult,
        artifacts: [EvaluationArtifact],
        semanticFailure: String?
    ) throws -> OperationReceipt? {
        guard let receipt else { return nil }
        let outputs = artifacts.map {
            OperationOutputArtifact(
                path: $0.sourceDescription,
                contentDigest: ContentDigest(data: $0.rawData).description,
                artifactID: $0.artifactID,
                byteDigest: $0.byteDigest,
                evaluationID: $0.evaluationID,
                resultID: $0.resultID,
                sampleCount: $0.samples.count,
                summaryMetricCount: $0.summaries.count,
                startTime: $0.startTime,
                durationInMilliseconds: $0.durationInMilliseconds
            )
        }
        let completed: OperationReceipt
        if let semanticFailure {
            completed = receipt.failing(
                with: process,
                outputs: outputs,
                message: semanticFailure
            )
        } else {
            completed = receipt.completing(
                with: process,
                outputs: outputs
            )
        }
        try OperationReceiptStore(
            directory: expandedURL(stateDirectory)
        ).save(completed)
        return completed
    }

    private func failOperation(
        _ receipt: OperationReceipt?,
        process: ProcessResult? = nil,
        message: String
    ) throws {
        guard let receipt else { return }
        let failed =
            process.map {
                receipt.failing(with: $0, message: message)
            }
            ?? receipt.failing(message: message)
        try OperationReceiptStore(
            directory: expandedURL(stateDirectory)
        ).save(failed)
    }

    private func minimumArtifactError(
        _ outputs: [ResolvedRunOutput],
        artifactsByOutput: [[EvaluationArtifact]],
        process: ProcessResult
    ) -> String? {
        guard process.status == 0 else {
            return nil
        }
        let artifactCount = artifactsByOutput.reduce(0) {
            $0 + $1.count
        }
        if artifactCount == 0, allowEmpty {
            return nil
        }
        for (output, artifacts) in zip(outputs, artifactsByOutput) {
            if let minimumCount = output.minimumCount,
                artifacts.count < minimumCount
            {
                return "Target output '\(output.role)' at \(output.url.path) "
                    + "requires at least \(minimumCount) artifact(s), but the "
                    + "run produced \(artifacts.count) there."
            }
        }
        if artifactCount == 0, !allowEmpty {
            return """
                The producer succeeded but no new or changed evaluation artifacts \
                were found under the requested results paths.
                """
        }
        return nil
    }

    private func emit(
        _ payload: RunPayload,
        output: ResolvedOutputOptions
    ) throws {
        switch output.format {
        case .text:
            guard let process = payload.process else {
                preconditionFailure("Fresh run payloads contain a process result.")
            }
            CLIOutput.emitRaw(process.standardOutput.data(using: .utf8) ?? Data())
            if !process.standardError.isEmpty {
                FileHandle.standardError.write(
                    Data(process.standardError.utf8)
                )
            }
            print(
                "Producer exit status: \(process.status). "
                    + "Collected \(payload.artifacts.count) artifact(s)."
            )
            for artifact in payload.artifacts {
                print("- \(artifact.path)")
            }
        case .json:
            try CLIOutput.emit(payload, options: output)
        case .jsonl, .rawJSON:
            preconditionFailure("Validated output format is exhaustive.")
        }
    }

    private func emitReplay(
        _ receipt: OperationReceipt,
        invocation: ResolvedRunInvocation,
        output: ResolvedOutputOptions
    ) throws {
        switch output.format {
        case .text:
            print(
                "Operation \(receipt.idempotencyKey) is "
                    + "\(receipt.state.rawValue); producer was not re-executed."
            )
            if let errorMessage = receipt.errorMessage {
                FileHandle.standardError.write(Data("\(errorMessage)\n".utf8))
            }
        case .json:
            let artifacts = try receipt.outputs.map {
                guard let artifact = ArtifactListItem(replaying: $0) else {
                    throw XCEvalCLIError.operationEvidenceUnavailable(
                        operationID: receipt.idempotencyKey,
                        component:
                            "the recorded artifact metadata for '\($0.path)'"
                    )
                }
                return artifact
            }
            try CLIOutput.emit(
                RunPayload(
                    producerCommand: invocation.command,
                    workingDirectory: invocation.workingDirectory?.path,
                    resultsPaths: invocation.outputs.map(\.url.path),
                    process: receipt.process,
                    artifacts: artifacts,
                    operationReceipt: receipt,
                    errorMessage: receipt.errorMessage
                ),
                options: output
            )
        case .jsonl, .rawJSON:
            preconditionFailure("Validated output format is exhaustive.")
        }
    }
}

private struct ResolvedRunInvocation {
    let command: [String]
    let workingDirectory: URL?
    let outputs: [ResolvedRunOutput]
    let environment: [String: String]
    let targetRevision: String?
    let selection: RunSelectionIdentity?
}

private struct ResolvedRunOutput {
    let role: String
    let url: URL
    let minimumCount: Int?
}

private struct RunRequestIdentity: Encodable {
    let command: [String]
    let workingDirectory: String?
    let resultsPath: String
    let targetRevision: String?
    let environmentDigest: String
    let selection: RunSelectionIdentity?
    let timeout: Double?
    let includeExisting: Bool
    let allowEmpty: Bool
    let minimumArtifactCount: Int?
}

private struct RunSelectionIdentity: Encodable {
    let path: String
    let contentDigest: String
    let sourceArtifactID: String?
}

private enum RunOperationClaim {
    case claimed(OperationReceipt, OperationReceiptLease)
    case existing(OperationReceipt)
}

struct TestCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "test",
        abstract: "Run xcodebuild tests and export Evaluations attachments.",
        discussion: """
            Pass normal xcodebuild arguments after '--'. xceval adds \
            -resultBundlePath, runs the tests with the selected Xcode, then calls \
            Apple's 'xcresulttool export evaluations' even when tests fail.
            """
    )

    @Option(
        name: .long,
        help: "Xcode.app or Contents/Developer path. Auto-discovered by default."
    )
    var xcode: String?

    @Option(
        name: .long,
        help: "Working directory containing the project, workspace, or package."
    )
    var workingDirectory: String?

    @Option(
        name: .long,
        help: "Path for the generated .xcresult bundle."
    )
    var resultBundlePath: String?

    @Option(
        name: .long,
        help: "Directory for exported .xcevalresult attachments."
    )
    var outputPath: String?

    @Option(
        name: .long,
        help: "Export attachments only for this test identifier."
    )
    var testID: String?

    @Flag(
        name: .long,
        help: "Export only attachments associated with test failures."
    )
    var onlyFailures = false

    @Flag(
        name: .long,
        help: "Replace existing result and export paths."
    )
    var force = false

    @OptionGroup var outputOptions: StandardOutputOptions

    @Argument(
        parsing: .postTerminator,
        help: "xcodebuild arguments, written after '--'."
    )
    var xcodebuildArguments: [String] = []

    mutating func run() throws {
        guard !xcodebuildArguments.isEmpty else {
            throw ValidationError(
                "Provide xcodebuild arguments after '--'."
            )
        }
        let includesResultBundlePath = xcodebuildArguments.contains {
            $0 == "-resultBundlePath"
                || $0.hasPrefix("-resultBundlePath=")
        }
        guard !includesResultBundlePath else {
            throw ValidationError(
                "Use --result-bundle-path instead of passing -resultBundlePath."
            )
        }

        let output = try outputOptions.resolve()
        let installation = try XcodeLocator.evaluationCapableInstallation(
            preferredPath: xcode
        )
        let locations = try prepareLocations()
        let process = try runXcodebuild(
            installation: installation,
            resultBundle: locations.resultBundle
        )
        let export = exportEvaluations(
            installation: installation,
            locations: locations
        )

        let payload = TestPayload(
            xcodebuildArguments: xcodebuildArguments,
            workingDirectory: workingDirectory.map {
                expandedURL($0).path
            },
            resultBundlePath: locations.resultBundle.path,
            outputDirectory: locations.outputDirectory.path,
            xcode: installation,
            process: process,
            exportedFiles: export.result?.files.map(\.path) ?? [],
            manifest: export.result?.manifest,
            exportError: export.error
        )
        try emit(payload, output: output)

        if process.status != 0 {
            throw ExitCode(process.status)
        }
        if export.error != nil {
            throw ExitCode.failure
        }
    }

    private func runXcodebuild(
        installation: XcodeInstallation,
        resultBundle: URL
    ) throws -> ProcessResult {
        try ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: [
                "xcodebuild"
            ] + xcodebuildArguments + [
                "-resultBundlePath",
                resultBundle.path
            ],
            currentDirectory: workingDirectory.map(expandedURL),
            environment: XcodeLocator.environment(for: installation)
        )
    }

    private func exportEvaluations(
        installation: XcodeInstallation,
        locations: (resultBundle: URL, outputDirectory: URL)
    ) -> TestExportOutcome {
        guard
            FileManager.default.fileExists(
                atPath: locations.resultBundle.path
            )
        else {
            return TestExportOutcome(
                result: nil,
                error: "xcodebuild did not create the requested result bundle."
            )
        }
        do {
            let result = try XcodeEvaluationExporter.export(
                xcresult: locations.resultBundle,
                outputDirectory: locations.outputDirectory,
                installation: installation,
                testID: testID,
                onlyFailures: onlyFailures
            )
            return TestExportOutcome(result: result, error: nil)
        } catch {
            return TestExportOutcome(
                result: nil,
                error: error.localizedDescription
            )
        }
    }

    private func prepareLocations() throws -> (
        resultBundle: URL,
        outputDirectory: URL
    ) {
        let fileManager = FileManager.default
        let resultBundle: URL
        if let resultBundlePath {
            resultBundle = expandedURL(resultBundlePath)
        } else {
            let root = fileManager.temporaryDirectory.appendingPathComponent(
                "xceval-test-\(UUID().uuidString)"
            )
            try fileManager.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            resultBundle = root.appendingPathComponent("Tests.xcresult")
        }
        let outputDirectory =
            outputPath.map(expandedURL)
            ?? resultBundle
            .deletingPathExtension()
            .appendingPathExtension("evaluations")

        let locations = [resultBundle, outputDirectory]
        let existingLocations = locations.filter {
            fileManager.fileExists(atPath: $0.path)
        }
        if !existingLocations.isEmpty {
            guard force else {
                throw ValidationError(
                    """
                    Output already exists at \(existingLocations[0].path). Pass --force \
                    to replace it.
                    """
                )
            }
            let protectedWorkingDirectory =
                workingDirectory.map(expandedURL)
                ?? URL(
                    fileURLWithPath: fileManager.currentDirectoryPath,
                    isDirectory: true
                )
            try validateForcedReplacement(
                targets: locations,
                protecting: [protectedWorkingDirectory]
            )
        }
        for location in existingLocations {
            try fileManager.removeItem(at: location)
        }
        try fileManager.createDirectory(
            at: resultBundle.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: outputDirectory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return (resultBundle, outputDirectory)
    }

    private func emit(
        _ payload: TestPayload,
        output: ResolvedOutputOptions
    ) throws {
        switch output.format {
        case .text:
            CLIOutput.emitRaw(payload.process.standardOutput.data(using: .utf8) ?? Data())
            if !payload.process.standardError.isEmpty {
                FileHandle.standardError.write(
                    Data(payload.process.standardError.utf8)
                )
            }
            print("xcodebuild exit status: \(payload.process.status)")
            print("Result bundle: \(payload.resultBundlePath)")
            print("Export directory: \(payload.outputDirectory)")
            print("Evaluation artifacts: \(payload.exportedFiles.count)")
            for file in payload.exportedFiles {
                print("- \(file)")
            }
            if let exportError = payload.exportError {
                print("Export error: \(exportError)")
            }
        case .json:
            try CLIOutput.emit(payload, options: output)
        case .jsonl, .rawJSON:
            preconditionFailure("Validated output format is exhaustive.")
        }
    }
}
