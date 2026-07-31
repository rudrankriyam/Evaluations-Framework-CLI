import Foundation

public enum ProcessLogError: LocalizedError, Equatable {
    case alreadyExists(String)
    case duplicateDestinations(String)
    case systemCall(operation: String, path: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .alreadyExists(let path):
            "Process log already exists and will not be replaced: \(path)."
        case .duplicateDestinations(let path):
            "Standard output and error logs must use different paths: \(path)."
        case .systemCall(let operation, let path, let code):
            "\(operation) failed for process log \(path) with errno \(code)."
        }
    }
}

/// Why a launched process stopped.
public enum ProcessTerminationReason: String, Codable, Sendable {
    /// The executable exited on its own.
    case exited
    /// The executable was terminated by an uncaught signal.
    case uncaughtSignal
    /// The configured timeout elapsed.
    case timedOut
    /// The task running the process was cancelled.
    case cancelled
}

/// File-backed logging and bounded output capture for a process.
public struct ProcessLogOptions: Sendable {
    /// A durable stdout log. A temporary file is used when this is `nil`.
    public let standardOutputURL: URL?
    /// A durable stderr log. A temporary file is used when this is `nil`.
    public let standardErrorURL: URL?
    /// Maximum bytes retained in each in-memory result value.
    public let maximumCapturedBytes: Int
    /// Maximum bytes written to each durable log.
    ///
    /// The collector continues draining the child after this limit is reached,
    /// but stops writing additional bytes to the file.
    public let maximumFileBytes: Int?

    public init(
        standardOutputURL: URL? = nil,
        standardErrorURL: URL? = nil,
        maximumCapturedBytes: Int = 1_048_576,
        maximumFileBytes: Int? = nil
    ) {
        self.standardOutputURL = standardOutputURL
        self.standardErrorURL = standardErrorURL
        self.maximumCapturedBytes = max(0, maximumCapturedBytes)
        self.maximumFileBytes = maximumFileBytes.map { max(0, $0) }
    }
}

/// Controls process lifetime independently of any CLI command.
public struct ProcessExecutionOptions: Sendable {
    /// Maximum wall-clock duration. `nil` disables the timeout.
    public let timeout: TimeInterval?
    /// Translate interactive termination signals into a recorded cancellation.
    ///
    /// This should be enabled by an executable's top-level process command,
    /// not by reusable library callers.
    public let handlesInterruptSignals: Bool
    /// Time allowed for graceful termination before sending `SIGKILL`.
    public let terminationGracePeriod: TimeInterval
    /// File-backed and bounded output behavior.
    public let logs: ProcessLogOptions

    public init(
        timeout: TimeInterval? = nil,
        handlesInterruptSignals: Bool = false,
        terminationGracePeriod: TimeInterval = 2,
        logs: ProcessLogOptions = ProcessLogOptions()
    ) {
        self.timeout = timeout.flatMap {
            $0.isFinite ? max(0, $0) : nil
        }
        self.handlesInterruptSignals = handlesInterruptSignals
        self.terminationGracePeriod = max(0, terminationGracePeriod)
        self.logs = logs
    }
}

/// Metadata for one captured process stream.
public struct ProcessLogResult: Sendable {
    /// Durable log location, or `nil` when the runner used ephemeral storage.
    public let url: URL?
    public let capturedBytes: Int
    public let writtenBytes: Int
    public let captureTruncated: Bool
    public let fileTruncated: Bool
}

public struct ProcessResult: Sendable {
    public let status: Int32
    public let terminationReason: ProcessTerminationReason
    public let terminationSignal: Int32?
    public let duration: TimeInterval
    public let processIdentifier: Int32
    /// The child-owned process group, when one was established safely.
    public let processGroupIdentifier: Int32?
    public let standardOutput: Data
    public let standardError: Data
    public let standardOutputLog: ProcessLogResult
    public let standardErrorLog: ProcessLogResult

    public var standardOutputString: String {
        String(data: standardOutput, encoding: .utf8) ?? ""
    }

    public var standardErrorString: String {
        String(data: standardError, encoding: .utf8) ?? ""
    }
}
