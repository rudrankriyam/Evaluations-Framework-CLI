import ArgumentParser
import Foundation
import XCEvalCore

struct ExportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export .xcevalresult attachments from an .xcresult bundle."
    )

    @Argument(help: "Path to an Xcode .xcresult bundle.")
    var path: String

    @Option(
        name: .long,
        help: "Destination directory. Defaults beside the .xcresult bundle."
    )
    var outputPath: String?

    @Option(
        name: .long,
        help: "Xcode.app or Contents/Developer path. Auto-discovered by default."
    )
    var xcode: String?

    @Option(
        name: .long,
        help: "Test identifier URL or identifier string."
    )
    var testID: String?

    @Flag(
        name: .long,
        help: "Export only attachments associated with test failures."
    )
    var onlyFailures = false

    @Flag(
        name: .long,
        help: "Replace an existing output directory."
    )
    var force = false

    @OptionGroup var outputOptions: StandardOutputOptions

    mutating func run() throws {
        let output = try outputOptions.resolve()
        let input = expandedURL(path)
        let destination =
            outputPath.map(expandedURL)
            ?? input.deletingPathExtension().appendingPathExtension("evaluations")
        try prepareDestination(input: input, destination: destination)

        let installation = try XcodeLocator.evaluationCapableInstallation(
            preferredPath: xcode
        )
        let result = try runExport(
            input: input,
            destination: destination,
            installation: installation
        )
        guard result.status == 0 else {
            throw XCEvalCommandError.processFailed(
                command: "xcresulttool export evaluations",
                status: result.status,
                message: result.standardErrorString
            )
        }

        let artifacts = loadExportArtifacts(from: destination)
        try emitExport(
            artifacts,
            input: input,
            destination: destination,
            installation: installation,
            output: output
        )
    }

    private func prepareDestination(input: URL, destination: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: input.path) else {
            throw ValidationError("The .xcresult bundle does not exist: \(input.path)")
        }
        guard fileManager.fileExists(atPath: destination.path) else { return }
        guard force else {
            throw ValidationError(
                "The output directory already exists. Pass --force to replace it."
            )
        }
        try fileManager.removeItem(at: destination)
    }

    private func runExport(
        input: URL,
        destination: URL,
        installation: XcodeInstallation
    ) throws -> ProcessResult {
        var arguments = [
            "xcresulttool",
            "export",
            "evaluations",
            "--path",
            input.path,
            "--output-path",
            destination.path
        ]
        if onlyFailures {
            arguments.append("--only-failures")
        }
        if let testID {
            arguments.append(contentsOf: ["--test-id", testID])
        }
        return try ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: arguments,
            environment: XcodeLocator.environment(for: installation)
        )
    }

    private func loadExportArtifacts(from destination: URL) -> ExportArtifacts {
        let fileManager = FileManager.default
        let manifestURL = destination.appendingPathComponent("manifest.json")
        let manifest = try? JSONValue.decode(Data(contentsOf: manifestURL))
        var files: [String] = []
        if let enumerator = fileManager.enumerator(
            at: destination,
            includingPropertiesForKeys: nil
        ) {
            for case let file as URL in enumerator
            where file.pathExtension == "xcevalresult" {
                files.append(file.path)
            }
        }
        files.sort()
        return ExportArtifacts(files: files, manifest: manifest)
    }

    private func emitExport(
        _ artifacts: ExportArtifacts,
        input: URL,
        destination: URL,
        installation: XcodeInstallation,
        output: ResolvedOutputOptions
    ) throws {
        switch output.format {
        case .text:
            print("Exported \(artifacts.files.count) evaluation artifact(s).")
            print("Output: \(destination.path)")
            for file in artifacts.files {
                print("- \(file)")
            }
        case .json:
            try CLIOutput.emit(
                ExportPayload(
                    xcresultPath: input.path,
                    outputDirectory: destination.path,
                    xcode: installation,
                    onlyFailures: onlyFailures,
                    testID: testID,
                    exportedFiles: artifacts.files,
                    manifest: artifacts.manifest
                ),
                options: output
            )
        case .jsonl, .rawJSON:
            preconditionFailure("Validated output format is exhaustive.")
        }
    }
}

struct SchemaCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "schema",
        abstract: "Print Apple's evaluation export manifest JSON Schema."
    )

    @Option(
        name: .long,
        help: "Xcode.app or Contents/Developer path. Auto-discovered by default."
    )
    var xcode: String?

    @Option(
        name: .long,
        help: "Requested xcresulttool schema version."
    )
    var schemaVersion: String?

    mutating func run() throws {
        let installation = try XcodeLocator.evaluationCapableInstallation(
            preferredPath: xcode
        )
        var arguments = [
            "xcresulttool",
            "export",
            "evaluations",
            "--schema"
        ]
        if let schemaVersion {
            arguments.append(contentsOf: ["--schema-version", schemaVersion])
        }
        let result = try ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: arguments,
            environment: XcodeLocator.environment(for: installation)
        )
        guard result.status == 0 else {
            throw XCEvalCommandError.processFailed(
                command: "xcresulttool export evaluations --schema",
                status: result.status,
                message: result.standardErrorString
            )
        }
        CLIOutput.emitRaw(result.standardOutput)
    }
}

struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Discover Xcode and report Evaluations tooling availability."
    )

    @Option(
        name: .long,
        help: "Xcode.app or Contents/Developer path to inspect."
    )
    var xcode: String?

    @Flag(
        name: .long,
        help: "Exit unsuccessfully unless Xcode evaluation export is available."
    )
    var requireExport = false

    @OptionGroup var outputOptions: StandardOutputOptions

    mutating func run() throws {
        let output = try outputOptions.resolve()
        let installations = XcodeLocator.installations(preferredPath: xcode)
        let selected = installations.first(where: {
            $0.exportsEvaluations && $0.macOSEvaluationsFramework != nil
        })
        let payload = DoctorPayload(
            evaluationExportAvailable: selected != nil,
            selectedXcode: selected,
            discoveredXcodes: installations,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString
        )

        switch output.format {
        case .text:
            printDoctor(selected)
        case .json:
            try CLIOutput.emit(payload, options: output)
        case .jsonl, .rawJSON:
            preconditionFailure("Validated output format is exhaustive.")
        }

        if requireExport, selected == nil {
            throw ValidationError(
                "Xcode evaluation export is required but unavailable."
            )
        }
    }

    private func printDoctor(_ selected: XcodeInstallation?) {
        print("Artifact inspection: available")
        guard let selected else {
            print("Evaluation export: unavailable")
            print("Install Xcode 27 or pass --xcode /path/to/Xcode.app.")
            return
        }
        let version = [selected.version, selected.build]
            .compactMap(\.self)
            .joined(separator: " ")
        print("Evaluation export: available")
        print("Xcode: \(version)")
        print("Developer directory: \(selected.developerDirectory)")
        print("Evaluations frameworks:")
        for framework in selected.frameworks {
            print("- \(framework.platform): \(framework.path)")
        }
    }
}

private struct ExportArtifacts {
    let files: [String]
    let manifest: JSONValue?
}

enum XCEvalCommandError: LocalizedError {
    case processFailed(command: String, status: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .processFailed(let command, let status, let message):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "'\(command)' failed with exit status \(status)."
            }
            return "'\(command)' failed with exit status \(status): \(detail)"
        }
    }
}
