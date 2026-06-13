import Foundation

public struct XcodeEvaluationExport: Sendable {
    public let outputDirectory: URL
    public let files: [URL]
    public let manifest: JSONValue?
}

public enum XcodeEvaluationExporter {
    public static func export(
        xcresult: URL,
        outputDirectory: URL,
        installation: XcodeInstallation,
        testID: String? = nil,
        onlyFailures: Bool = false
    ) throws -> XcodeEvaluationExport {
        var arguments = [
            "xcresulttool",
            "export",
            "evaluations",
            "--path",
            xcresult.path,
            "--output-path",
            outputDirectory.path
        ]
        if onlyFailures {
            arguments.append("--only-failures")
        }
        if let testID {
            arguments.append(contentsOf: ["--test-id", testID])
        }

        let result = try ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: arguments,
            environment: XcodeLocator.environment(for: installation)
        )
        guard result.status == 0 else {
            throw XcodeEvaluationExportError.processFailed(
                status: result.status,
                message: result.standardErrorString
            )
        }

        let manifestURL = outputDirectory.appendingPathComponent("manifest.json")
        let manifest = try? JSONValue.decode(Data(contentsOf: manifestURL))
        let files =
            (try? EvaluationArtifactLoader.artifactFiles(
                in: outputDirectory
            )) ?? []
        return XcodeEvaluationExport(
            outputDirectory: outputDirectory,
            files: files.filter { $0.pathExtension == "xcevalresult" },
            manifest: manifest
        )
    }
}

public enum XcodeEvaluationExportError: LocalizedError {
    case processFailed(status: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case .processFailed(let status, let message):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "'xcresulttool export evaluations' failed with exit status \(status)."
            }
            return """
                'xcresulttool export evaluations' failed with exit status \
                \(status): \(detail)
                """
        }
    }
}
