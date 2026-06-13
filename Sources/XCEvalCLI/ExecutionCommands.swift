import ArgumentParser
import Foundation
import XCEvalCore

struct RunCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run any typed evaluation producer and collect its artifacts.",
        discussion: """
            The command after '--' remains responsible for importing \
            Evaluations.framework and saving .xcevalresult files. xceval records \
            the process result and returns every new or changed artifact.
            """
    )

    @Option(
        name: .long,
        help: "File or directory where the producer writes evaluation artifacts."
    )
    var resultsPath: String

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

    @OptionGroup var outputOptions: StandardOutputOptions

    @Argument(
        parsing: .postTerminator,
        help: "Producer command and arguments, written after '--'."
    )
    var producerCommand: [String] = []

    mutating func run() throws {
        guard !producerCommand.isEmpty else {
            throw ValidationError(
                "Provide a producer command after '--'."
            )
        }
        let output = try outputOptions.resolve()
        let resultsURL = resolvedResultsURL()
        let before = artifactSnapshot(at: resultsURL)
        let process = try ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: producerCommand,
            currentDirectory: workingDirectory.map(expandedURL)
        )
        let after = artifactSnapshot(at: resultsURL)
        let changedPaths = after.keys.filter {
            includeExisting || before[$0] != after[$0]
        }.sorted()
        let artifacts = try changedPaths.flatMap {
            try EvaluationArtifactLoader.load(
                from: URL(fileURLWithPath: $0)
            )
        }
        let payload = RunPayload(
            producerCommand: producerCommand,
            workingDirectory: workingDirectory.map {
                expandedURL($0).path
            },
            resultsPath: resultsURL.path,
            process: process,
            artifacts: artifacts
        )
        try emit(payload, output: output)

        if process.status != 0 {
            throw ExitCode(process.status)
        }
        if artifacts.isEmpty, !allowEmpty {
            throw ValidationError(
                """
                The producer succeeded but no new or changed evaluation artifacts \
                were found under \(resultsURL.path).
                """
            )
        }
    }

    private func resolvedResultsURL() -> URL {
        let expandedPath = (resultsPath as NSString).expandingTildeInPath
        if (expandedPath as NSString).isAbsolutePath {
            return expandedURL(expandedPath)
        }
        if let workingDirectory {
            return expandedURL(workingDirectory)
                .appendingPathComponent(expandedPath)
                .standardizedFileURL
        }
        return expandedURL(expandedPath)
    }

    private func emit(
        _ payload: RunPayload,
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
            print(
                "Producer exit status: \(payload.process.status). "
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

        for location in [resultBundle, outputDirectory]
        where fileManager.fileExists(atPath: location.path) {
            guard force else {
                throw ValidationError(
                    """
                    Output already exists at \(location.path). Pass --force \
                    to replace it.
                    """
                )
            }
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
