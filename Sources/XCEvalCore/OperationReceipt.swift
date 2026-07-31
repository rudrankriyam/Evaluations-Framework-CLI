import CryptoKit
import Darwin
import Foundation

/// Durable lifecycle states for one idempotent operation.
public enum OperationReceiptState: String, Codable, Sendable {
    case running
    case succeeded
    case failed
    case cancelled
    case timedOut

    public var isTerminal: Bool {
        self != .running
    }
}

/// A process outcome small enough to persist in an operation receipt.
public struct OperationProcessOutcome: Codable, Equatable, Sendable {
    public let status: Int32
    public let terminationReason: ProcessTerminationReason
    public let terminationSignal: Int32?
    public let duration: TimeInterval
    public let processIdentifier: Int32
    public let processGroupIdentifier: Int32?
    public let standardOutputLog: String?
    public let standardErrorLog: String?
    public let standardOutputTruncated: Bool
    public let standardErrorTruncated: Bool

    public init(_ result: ProcessResult) {
        status = result.status
        terminationReason = result.terminationReason
        terminationSignal = result.terminationSignal
        duration = result.duration
        processIdentifier = result.processIdentifier
        processGroupIdentifier = result.processGroupIdentifier
        standardOutputLog = result.standardOutputLog.url?.path
        standardErrorLog = result.standardErrorLog.url?.path
        standardOutputTruncated =
            result.standardOutputLog.fileTruncated
            || result.standardOutputLog.captureTruncated
        standardErrorTruncated =
            result.standardErrorLog.fileTruncated
            || result.standardErrorLog.captureTruncated
    }
}

/// One material output associated with an operation.
public struct OperationOutputArtifact: Codable, Equatable, Sendable {
    public let path: String
    public let contentDigest: String?
    public let artifactID: String?
    public let byteDigest: String?
    public let evaluationID: String?
    public let resultID: String?
    public let sampleCount: Int?
    public let summaryMetricCount: Int?
    public let startTime: String?
    public let durationInMilliseconds: Double?

    public init(
        path: String,
        contentDigest: String? = nil,
        artifactID: String? = nil,
        byteDigest: String? = nil,
        evaluationID: String? = nil,
        resultID: String? = nil,
        sampleCount: Int? = nil,
        summaryMetricCount: Int? = nil,
        startTime: String? = nil,
        durationInMilliseconds: Double? = nil
    ) {
        self.path = path
        self.contentDigest = contentDigest
        self.artifactID = artifactID
        self.byteDigest = byteDigest
        self.evaluationID = evaluationID
        self.resultID = resultID
        self.sampleCount = sampleCount
        self.summaryMetricCount = summaryMetricCount
        self.startTime = startTime
        self.durationInMilliseconds = durationInMilliseconds
    }
}

/// An atomically persisted receipt keyed by a caller-stable idempotency key.
public struct OperationReceipt: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = "xceval.operation-receipt/v1"

    public let schemaVersion: String
    public let operationID: UUID
    public let idempotencyKey: String
    public let operation: String
    public let attempt: Int
    public let state: OperationReceiptState
    public let startedAt: Date
    public let endedAt: Date?
    public let inputDigest: String?
    public let process: OperationProcessOutcome?
    public let outputs: [OperationOutputArtifact]
    public let errorMessage: String?

    public init(
        operationID: UUID = UUID(),
        idempotencyKey: String,
        operation: String,
        attempt: Int = 1,
        state: OperationReceiptState = .running,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        inputDigest: String? = nil,
        process: OperationProcessOutcome? = nil,
        outputs: [OperationOutputArtifact] = [],
        errorMessage: String? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.operationID = operationID
        self.idempotencyKey = idempotencyKey
        self.operation = operation
        self.attempt = max(1, attempt)
        self.state = state
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.inputDigest = inputDigest
        self.process = process
        self.outputs = outputs
        self.errorMessage = errorMessage
    }

    public func completing(
        with result: ProcessResult,
        outputs: [OperationOutputArtifact] = [],
        errorMessage: String? = nil,
        endedAt: Date = Date()
    ) -> OperationReceipt {
        let state: OperationReceiptState
        switch result.terminationReason {
        case .cancelled:
            state = .cancelled
        case .timedOut:
            state = .timedOut
        case .exited, .uncaughtSignal:
            state = result.status == 0 ? .succeeded : .failed
        }
        return terminal(
            state: state,
            process: OperationProcessOutcome(result),
            outputs: outputs,
            errorMessage: errorMessage,
            endedAt: endedAt
        )
    }

    public func failing(
        message: String,
        endedAt: Date = Date()
    ) -> OperationReceipt {
        terminal(
            state: .failed,
            process: process,
            outputs: outputs,
            errorMessage: message,
            endedAt: endedAt
        )
    }

    public func failing(
        with result: ProcessResult,
        outputs: [OperationOutputArtifact] = [],
        message: String,
        endedAt: Date = Date()
    ) -> OperationReceipt {
        let state: OperationReceiptState
        switch result.terminationReason {
        case .cancelled:
            state = .cancelled
        case .timedOut:
            state = .timedOut
        case .exited, .uncaughtSignal:
            state = .failed
        }
        return terminal(
            state: state,
            process: OperationProcessOutcome(result),
            outputs: outputs,
            errorMessage: message,
            endedAt: endedAt
        )
    }

    private func terminal(
        state: OperationReceiptState,
        process: OperationProcessOutcome?,
        outputs: [OperationOutputArtifact],
        errorMessage: String?,
        endedAt: Date
    ) -> OperationReceipt {
        OperationReceipt(
            operationID: operationID,
            idempotencyKey: idempotencyKey,
            operation: operation,
            attempt: attempt,
            state: state,
            startedAt: startedAt,
            endedAt: endedAt,
            inputDigest: inputDigest,
            process: process,
            outputs: outputs,
            errorMessage: errorMessage
        )
    }
}

/// Result of trying to claim an idempotency key.
public enum OperationReceiptClaim: Sendable {
    case claimed(OperationReceipt, OperationReceiptLease)
    case existing(OperationReceipt)
}

/// An exclusive cross-process lease for a running operation receipt.
///
/// Keep this value alive until the receipt reaches a terminal state. The
/// operating system releases the advisory lock if the executor exits or
/// crashes, allowing the next identical claim to recover the operation.
public final class OperationReceiptLease: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32?
    private var marker: OperationExecutionMarker?

    fileprivate init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        release()
    }

    /// Records that the claimed producer returned before its terminal receipt
    /// is persisted.
    ///
    /// A later claimant treats this durable marker as an ambiguous completed
    /// outcome instead of executing the producer a second time.
    public func markExecutionFinished() throws {
        lock.lock()
        defer { lock.unlock() }
        guard let descriptor, let marker else {
            throw OperationReceiptStoreError.invalidLifecycleEvidence
        }
        try writeExecutionMarkerState(.finished, to: descriptor)
        self.marker = marker.withState(.finished)
    }

    public func release() {
        let descriptor = lock.withLock {
            defer { self.descriptor = nil }
            return self.descriptor
        }
        guard let descriptor else { return }
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }

    fileprivate func beginExecution(_ receipt: OperationReceipt) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let descriptor else {
            throw OperationReceiptStoreError.invalidLifecycleEvidence
        }
        let marker = OperationExecutionMarker(
            state: .running,
            operationID: receipt.operationID,
            attempt: receipt.attempt
        )
        try writeExecutionMarker(marker, to: descriptor)
        self.marker = marker
    }
}

/// Cross-process receipt storage with exclusive-create claims and atomic updates.
public struct OperationReceiptStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func receiptURL(for idempotencyKey: String) -> URL {
        directory.appendingPathComponent(
            "\(idempotencyKeyDigest(idempotencyKey)).json"
        )
    }

    /// Claims the execution lease for an idempotency key.
    ///
    /// Concurrent callers receive the current running receipt instead of
    /// starting the same operation twice. If the previous executor exited
    /// without terminalizing its receipt, the abandoned lease is recovered as
    /// the next attempt.
    public func claim(_ receipt: OperationReceipt) throws -> OperationReceiptClaim {
        try validate(receipt)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = receiptURL(for: receipt.idempotencyKey)
        let claimURL = claimURL(for: receipt.idempotencyKey)
        let descriptor = Darwin.open(
            claimURL.path,
            O_RDWR | O_CREAT | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor != -1 else {
            throw OperationReceiptStoreError.systemCall(
                operation: "open",
                code: errno
            )
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            _ = close(descriptor)
            if code == EWOULDBLOCK {
                return .existing(
                    try waitForReceipt(idempotencyKey: receipt.idempotencyKey)
                )
            }
            throw OperationReceiptStoreError.systemCall(
                operation: "lock claim",
                code: code
            )
        }
        let lease = OperationReceiptLease(descriptor: descriptor)

        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let existing = try loadPersisted(
                    idempotencyKey: receipt.idempotencyKey
                )
                guard
                    existing.state == .running,
                    existing.operation == receipt.operation,
                    existing.inputDigest == receipt.inputDigest
                else {
                    lease.release()
                    return .existing(existing)
                }
                try rejectAmbiguousExecution(
                    for: existing,
                    marker: readExecutionMarker(from: descriptor)
                )
                let recovered = OperationReceipt(
                    operationID: existing.operationID,
                    idempotencyKey: existing.idempotencyKey,
                    operation: existing.operation,
                    attempt:
                        existing.attempt < Int.max
                        ? existing.attempt + 1
                        : Int.max,
                    startedAt: receipt.startedAt,
                    inputDigest: existing.inputDigest
                )
                try lease.beginExecution(recovered)
                try atomicWrite(encoded(recovered), to: url)
                return .claimed(recovered, lease)
            }
            try lease.beginExecution(receipt)
            try atomicWrite(encoded(receipt), to: url)
            return .claimed(receipt, lease)
        } catch {
            lease.release()
            throw error
        }
    }

    /// Atomically replaces an existing receipt with a later state.
    public func save(_ receipt: OperationReceipt) throws {
        try validate(receipt)
        let url = receiptURL(for: receipt.idempotencyKey)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw OperationReceiptStoreError.receiptNotFound(
                receipt.idempotencyKey
            )
        }
        let existing = try loadPersisted(
            idempotencyKey: receipt.idempotencyKey
        )
        guard
            existing.operationID == receipt.operationID,
            existing.operation == receipt.operation,
            existing.attempt == receipt.attempt
        else {
            throw OperationReceiptStoreError.receiptIdentityMismatch
        }
        guard !existing.state.isTerminal else {
            throw OperationReceiptStoreError.terminalReceiptImmutable
        }
        try atomicWrite(encoded(receipt), to: url)
    }

    public func load(idempotencyKey: String) throws -> OperationReceipt {
        let receipt = try loadPersisted(idempotencyKey: idempotencyKey)
        if receipt.state == .running {
            try rejectAmbiguousExecutionIfLeaseIsAbandoned(for: receipt)
        }
        return receipt
    }

    private func loadPersisted(
        idempotencyKey: String
    ) throws -> OperationReceipt {
        let url = receiptURL(for: idempotencyKey)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw OperationReceiptStoreError.receiptNotFound(idempotencyKey)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let receipt = try decoder.decode(
            OperationReceipt.self,
            from: Data(contentsOf: url)
        )
        try validate(receipt)
        guard receipt.idempotencyKey == idempotencyKey else {
            throw OperationReceiptStoreError.idempotencyKeyMismatch
        }
        return receipt
    }

    private func rejectAmbiguousExecutionIfLeaseIsAbandoned(
        for receipt: OperationReceipt
    ) throws {
        let url = claimURL(for: receipt.idempotencyKey)
        let descriptor = Darwin.open(url.path, O_RDWR | O_CLOEXEC)
        if descriptor == -1, errno == ENOENT {
            return
        }
        guard descriptor != -1 else {
            throw OperationReceiptStoreError.systemCall(
                operation: "open claim",
                code: errno
            )
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            _ = close(descriptor)
            if code == EWOULDBLOCK {
                return
            }
            throw OperationReceiptStoreError.systemCall(
                operation: "lock claim",
                code: code
            )
        }
        defer {
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
        }
        try rejectAmbiguousExecution(
            for: receipt,
            marker: readExecutionMarker(from: descriptor)
        )
    }

    private func rejectAmbiguousExecution(
        for receipt: OperationReceipt,
        marker: OperationExecutionMarkerRead
    ) throws {
        switch marker {
        case .none:
            return
        case .valid(let marker) where marker.state == .running:
            return
        case .valid, .malformed:
            throw OperationReceiptStoreError.executionOutcomeAmbiguous(
                receipt.idempotencyKey
            )
        }
    }

    private func validate(_ receipt: OperationReceipt) throws {
        guard receipt.schemaVersion == OperationReceipt.currentSchemaVersion else {
            throw OperationReceiptStoreError.unsupportedSchema(
                receipt.schemaVersion
            )
        }
        guard
            !receipt.idempotencyKey.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
        else {
            throw OperationReceiptStoreError.emptyIdempotencyKey
        }
        guard
            !receipt.operation.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
        else {
            throw OperationReceiptStoreError.emptyOperation
        }
        guard receipt.state.isTerminal == (receipt.endedAt != nil) else {
            throw OperationReceiptStoreError.invalidTerminalState
        }
        if let endedAt = receipt.endedAt, endedAt < receipt.startedAt {
            throw OperationReceiptStoreError.invalidLifecycleEvidence
        }
        switch receipt.state {
        case .running:
            guard receipt.process == nil, receipt.outputs.isEmpty else {
                throw OperationReceiptStoreError.invalidLifecycleEvidence
            }
        case .succeeded:
            guard
                receipt.process?.terminationReason == .exited,
                receipt.process?.status == 0
            else {
                throw OperationReceiptStoreError.invalidLifecycleEvidence
            }
        case .timedOut:
            guard receipt.process?.terminationReason == .timedOut else {
                throw OperationReceiptStoreError.invalidLifecycleEvidence
            }
        case .cancelled:
            guard receipt.process?.terminationReason == .cancelled else {
                throw OperationReceiptStoreError.invalidLifecycleEvidence
            }
        case .failed:
            guard
                receipt.process?.terminationReason != .timedOut,
                receipt.process?.terminationReason != .cancelled
            else {
                throw OperationReceiptStoreError.invalidLifecycleEvidence
            }
        }
    }

    private func encoded(_ receipt: OperationReceipt) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes
        ]
        var data = try encoder.encode(receipt)
        data.append(0x0A)
        return data
    }

    private func claimURL(for idempotencyKey: String) -> URL {
        directory.appendingPathComponent(
            "\(idempotencyKeyDigest(idempotencyKey)).claim"
        )
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        let temporaryURL = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )
        let descriptor = Darwin.open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL,
            S_IRUSR | S_IWUSR
        )
        guard descriptor != -1 else {
            throw OperationReceiptStoreError.systemCall(
                operation: "open temporary receipt",
                code: errno
            )
        }
        do {
            try writeAll(data, to: descriptor)
            guard fsync(descriptor) == 0 else {
                throw OperationReceiptStoreError.systemCall(
                    operation: "fsync receipt",
                    code: errno
                )
            }
            guard close(descriptor) == 0 else {
                throw OperationReceiptStoreError.systemCall(
                    operation: "close receipt",
                    code: errno
                )
            }
            guard rename(temporaryURL.path, url.path) == 0 else {
                throw OperationReceiptStoreError.systemCall(
                    operation: "rename receipt",
                    code: errno
                )
            }
            try synchronizeDirectory()
        } catch {
            _ = close(descriptor)
            _ = unlink(temporaryURL.path)
            throw error
        }
    }

    private func synchronizeDirectory() throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY)
        guard descriptor != -1 else {
            throw OperationReceiptStoreError.systemCall(
                operation: "open receipt directory",
                code: errno
            )
        }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw OperationReceiptStoreError.systemCall(
                operation: "fsync receipt directory",
                code: errno
            )
        }
    }

    private func waitForReceipt(
        idempotencyKey: String
    ) throws -> OperationReceipt {
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        repeat {
            if FileManager.default.fileExists(
                atPath: receiptURL(for: idempotencyKey).path
            ) {
                if let receipt = try? load(idempotencyKey: idempotencyKey) {
                    return receipt
                }
            }
            Thread.sleep(forTimeInterval: 0.01)
        } while DispatchTime.now().uptimeNanoseconds < deadline
        throw OperationReceiptStoreError.claimPending(idempotencyKey)
    }
}

public enum OperationReceiptStoreError: LocalizedError, Equatable {
    case emptyIdempotencyKey
    case emptyOperation
    case unsupportedSchema(String)
    case invalidTerminalState
    case invalidLifecycleEvidence
    case receiptNotFound(String)
    case claimPending(String)
    case executionOutcomeAmbiguous(String)
    case idempotencyKeyMismatch
    case receiptIdentityMismatch
    case terminalReceiptImmutable
    case systemCall(operation: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .emptyIdempotencyKey:
            "Operation idempotency keys must not be empty."
        case .emptyOperation:
            "Operation names must not be empty."
        case .unsupportedSchema(let schema):
            "Unsupported operation receipt schema '\(schema)'."
        case .invalidTerminalState:
            "Terminal receipts require endedAt; running receipts must omit it."
        case .invalidLifecycleEvidence:
            "The receipt state contradicts its process or lifecycle evidence."
        case .receiptNotFound(let key):
            "No operation receipt exists for idempotency key '\(key)'."
        case .claimPending(let key):
            "The operation claim for idempotency key '\(key)' has no receipt yet."
        case .executionOutcomeAmbiguous(let key):
            "The producer for idempotency key '\(key)' finished, but its terminal "
                + "receipt was not committed. Refusing to execute it again."
        case .idempotencyKeyMismatch:
            "The receipt contents do not match the requested idempotency key."
        case .receiptIdentityMismatch:
            "An operation receipt update cannot change the claimed identity."
        case .terminalReceiptImmutable:
            "A terminal operation receipt cannot be replaced."
        case .systemCall(let operation, let code):
            "Operation receipt \(operation) failed with errno \(code)."
        }
    }
}

private enum OperationExecutionMarkerState: String {
    case running = "running_"
    case finished = "finished"
}

private struct OperationExecutionMarker {
    static let schemaVersion = "xceval.operation-execution/v1"

    let state: OperationExecutionMarkerState
    let operationID: UUID
    let attempt: Int

    func withState(
        _ state: OperationExecutionMarkerState
    ) -> OperationExecutionMarker {
        OperationExecutionMarker(
            state: state,
            operationID: operationID,
            attempt: attempt
        )
    }
}

private enum OperationExecutionMarkerRead {
    case none
    case valid(OperationExecutionMarker)
    case malformed
}

private func idempotencyKeyDigest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map {
        String(format: "%02x", $0)
    }.joined()
}

private func writeExecutionMarker(
    _ marker: OperationExecutionMarker,
    to descriptor: Int32
) throws {
    let data = Data(
        """
        \(marker.state.rawValue)
        \(OperationExecutionMarker.schemaVersion)
        \(marker.operationID.uuidString)
        \(marker.attempt)

        """.utf8
    )
    guard lseek(descriptor, 0, SEEK_SET) != -1 else {
        throw OperationReceiptStoreError.systemCall(
            operation: "seek execution marker",
            code: errno
        )
    }
    try writeAll(data, to: descriptor)
    guard ftruncate(descriptor, off_t(data.count)) == 0 else {
        throw OperationReceiptStoreError.systemCall(
            operation: "truncate execution marker",
            code: errno
        )
    }
    guard fsync(descriptor) == 0 else {
        throw OperationReceiptStoreError.systemCall(
            operation: "fsync execution marker",
            code: errno
        )
    }
}

private func writeExecutionMarkerState(
    _ state: OperationExecutionMarkerState,
    to descriptor: Int32
) throws {
    let data = Data(state.rawValue.utf8)
    try data.withUnsafeBytes { buffer in
        guard let baseAddress = buffer.baseAddress else { return }
        var offset = 0
        while offset < buffer.count {
            let count = pwrite(
                descriptor,
                baseAddress.advanced(by: offset),
                buffer.count - offset,
                off_t(offset)
            )
            if count == -1 {
                if errno == EINTR {
                    continue
                }
                throw OperationReceiptStoreError.systemCall(
                    operation: "write execution marker",
                    code: errno
                )
            }
            offset += count
        }
    }
    guard fsync(descriptor) == 0 else {
        throw OperationReceiptStoreError.systemCall(
            operation: "fsync execution marker",
            code: errno
        )
    }
}

private func readExecutionMarker(
    from descriptor: Int32
) throws -> OperationExecutionMarkerRead {
    guard lseek(descriptor, 0, SEEK_SET) != -1 else {
        throw OperationReceiptStoreError.systemCall(
            operation: "seek execution marker",
            code: errno
        )
    }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 512)
    while true {
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        if count == 0 {
            break
        }
        if count == -1 {
            if errno == EINTR {
                continue
            }
            throw OperationReceiptStoreError.systemCall(
                operation: "read execution marker",
                code: errno
            )
        }
        data.append(buffer, count: count)
        if data.count > 4_096 {
            return .malformed
        }
    }
    guard !data.isEmpty else {
        return .none
    }
    guard
        let value = String(data: data, encoding: .utf8),
        value.hasSuffix("\n"),
        value.split(separator: "\n").count == 4
    else {
        return .malformed
    }
    let fields = value.split(separator: "\n")
    guard
        let state = OperationExecutionMarkerState(
            rawValue: String(fields[0])
        ),
        fields[1] == OperationExecutionMarker.schemaVersion[...],
        let operationID = UUID(uuidString: String(fields[2])),
        let attempt = Int(fields[3]),
        attempt > 0
    else {
        return .malformed
    }
    return .valid(
        OperationExecutionMarker(
            state: state,
            operationID: operationID,
            attempt: attempt
        )
    )
}

private func writeAll(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { buffer in
        guard let baseAddress = buffer.baseAddress else { return }
        var offset = 0
        while offset < buffer.count {
            let count = Darwin.write(
                descriptor,
                baseAddress.advanced(by: offset),
                buffer.count - offset
            )
            if count == -1 {
                if errno == EINTR {
                    continue
                }
                throw OperationReceiptStoreError.systemCall(
                    operation: "write receipt",
                    code: errno
                )
            }
            offset += count
        }
    }
}
