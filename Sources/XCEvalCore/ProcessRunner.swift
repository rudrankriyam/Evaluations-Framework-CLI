import Foundation

public struct ProcessResult: Sendable {
    public let status: Int32
    public let standardOutput: Data
    public let standardError: Data

    public var standardOutputString: String {
        String(data: standardOutput, encoding: .utf8) ?? ""
    }

    public var standardErrorString: String {
        String(data: standardError, encoding: .utf8) ?? ""
    }
}

public enum ProcessRunner {
    public static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ProcessResult {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("xceval-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let stdoutURL = temporaryDirectory.appendingPathComponent("stdout")
        let stderrURL = temporaryDirectory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)

        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        try stdout.synchronize()
        try stderr.synchronize()

        return ProcessResult(
            status: process.terminationStatus,
            standardOutput: try Data(contentsOf: stdoutURL),
            standardError: try Data(contentsOf: stderrURL)
        )
    }
}
