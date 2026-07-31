import Darwin
import Foundation

public enum ProcessRunner {
    public static func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        options: ProcessExecutionOptions = ProcessExecutionOptions()
    ) throws -> ProcessResult {
        try runBlocking(
            executable: executable,
            arguments: arguments,
            currentDirectory: currentDirectory,
            environment: environment,
            options: options,
            controller: ProcessController()
        )
    }

    /// Runs a process while propagating Swift task cancellation to the child.
    ///
    /// Cancellation is reported in `ProcessResult` after the child exits rather
    /// than throwing `CancellationError`, which allows callers to persist a
    /// complete terminal receipt.
    public static func runAsync(
        executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        options: ProcessExecutionOptions = ProcessExecutionOptions()
    ) async throws -> ProcessResult {
        let controller = ProcessController()
        let operation = Task.detached {
            try runBlocking(
                executable: executable,
                arguments: arguments,
                currentDirectory: currentDirectory,
                environment: environment,
                options: options,
                controller: controller
            )
        }
        return try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            controller.requestTermination(reason: .cancelled)
        }
    }

    private static func runBlocking(
        executable: URL,
        arguments: [String],
        currentDirectory: URL?,
        environment: [String: String],
        options: ProcessExecutionOptions,
        controller: ProcessController
    ) throws -> ProcessResult {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("xceval-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let stdoutURL =
            options.logs.standardOutputURL
            ?? temporaryDirectory.appendingPathComponent("stdout")
        let stderrURL =
            options.logs.standardErrorURL
            ?? temporaryDirectory.appendingPathComponent("stderr")
        try validateLogDestinations(options.logs)
        let stdoutCollector = try ProcessLogCollector(
            url: stdoutURL,
            reportedURL: options.logs.standardOutputURL,
            maximumCapturedBytes: options.logs.maximumCapturedBytes,
            maximumFileBytes: options.logs.maximumFileBytes
        )
        let stderrCollector: ProcessLogCollector
        do {
            stderrCollector = try ProcessLogCollector(
                url: stderrURL,
                reportedURL: options.logs.standardErrorURL,
                maximumCapturedBytes: options.logs.maximumCapturedBytes,
                maximumFileBytes: options.logs.maximumFileBytes
            )
        } catch {
            stdoutCollector.discardCreatedLog()
            throw error
        }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let readers = ProcessPipeReaders(
            standardOutput: stdoutPipe.fileHandleForReading,
            standardError: stderrPipe.fileHandleForReading,
            standardOutputCollector: stdoutCollector,
            standardErrorCollector: stderrCollector
        )

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.environment = environment
        process.standardOutput = stdoutPipe.fileHandleForWriting
        process.standardError = stderrPipe.fileHandleForWriting
        let startedAt = DispatchTime.now().uptimeNanoseconds
        do {
            try readers.start()
            try process.run()
        } catch {
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            readers.finish()
            throw error
        }
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        let processIdentifier = process.processIdentifier
        let ownsProcessGroup = setpgid(processIdentifier, processIdentifier) == 0
        controller.register(
            process: process,
            processIdentifier: processIdentifier,
            ownsProcessGroup: ownsProcessGroup,
            gracePeriod: options.terminationGracePeriod
        )
        let interruptSubscription =
            options.handlesInterruptSignals
            ? ProcessInterruptSignalRelay.shared.subscribe {
                controller.requestTermination(reason: .cancelled)
            }
            : nil
        defer {
            if let interruptSubscription {
                ProcessInterruptSignalRelay.shared.unsubscribe(
                    interruptSubscription
                )
            }
        }

        let timeoutDeadline = options.timeout.map { timeout in
            let available = UInt64.max - startedAt
            let nanoseconds = timeout * 1_000_000_000
            if nanoseconds >= Double(available) {
                return UInt64.max
            }
            return startedAt + UInt64(nanoseconds)
        }
        while process.isRunning {
            if let timeoutDeadline,
                DispatchTime.now().uptimeNanoseconds >= timeoutDeadline
            {
                controller.requestTermination(reason: .timedOut)
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()
        controller.markFinished()
        readers.finish()

        let endedAt = DispatchTime.now().uptimeNanoseconds
        let duration = Double(endedAt - startedAt) / 1_000_000_000
        let requestedReason = controller.requestedReason
        let reason =
            requestedReason
            ?? (process.terminationReason == .uncaughtSignal
                ? .uncaughtSignal
                : .exited)
        let signal =
            process.terminationReason == .uncaughtSignal
            ? process.terminationStatus
            : nil
        let stdout = try stdoutCollector.result()
        let stderr = try stderrCollector.result()

        return ProcessResult(
            status: process.terminationStatus,
            terminationReason: reason,
            terminationSignal: signal,
            duration: duration,
            processIdentifier: processIdentifier,
            processGroupIdentifier: ownsProcessGroup
                ? processIdentifier
                : nil,
            standardOutput: stdout.data,
            standardError: stderr.data,
            standardOutputLog: stdout.metadata,
            standardErrorLog: stderr.metadata
        )
    }

    private static func validateLogDestinations(
        _ options: ProcessLogOptions
    ) throws {
        let destinations = [
            options.standardOutputURL,
            options.standardErrorURL
        ].compactMap(\.self).map {
            $0.standardizedFileURL.resolvingSymlinksInPath()
        }
        if destinations.count == 2, destinations[0] == destinations[1] {
            throw ProcessLogError.duplicateDestinations(
                destinations[0].path
            )
        }
        if let existing = destinations.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) {
            throw ProcessLogError.alreadyExists(existing.path)
        }
    }
}

private typealias ProcessSignalHandler = @convention(c) (Int32) -> Void

/// Relays interactive process signals outside the async-signal-unsafe handler.
///
/// The relay is installed only after the child launches so the child retains
/// the default signal disposition. Multiple in-process runners share the relay
/// and restore the embedding process's previous handlers after the final
/// subscription ends.
private final class ProcessInterruptSignalRelay: @unchecked Sendable {
    static let shared = ProcessInterruptSignalRelay()

    private let lock = NSLock()
    private let queue = DispatchQueue(
        label: "dev.xceval.process-interrupt-signals"
    )
    private var callbacks: [UUID: @Sendable () -> Void] = [:]
    private var interruptSource: DispatchSourceSignal?
    private var terminationSource: DispatchSourceSignal?
    private var previousInterruptHandler: ProcessSignalHandler?
    private var previousTerminationHandler: ProcessSignalHandler?

    func subscribe(_ callback: @escaping @Sendable () -> Void) -> UUID {
        lock.withLock {
            if callbacks.isEmpty {
                install()
            }
            let token = UUID()
            callbacks[token] = callback
            return token
        }
    }

    func unsubscribe(_ token: UUID) {
        lock.withLock {
            callbacks[token] = nil
            if callbacks.isEmpty {
                uninstall()
            }
        }
    }

    private func install() {
        previousInterruptHandler = Darwin.signal(SIGINT, SIG_IGN)
        previousTerminationHandler = Darwin.signal(SIGTERM, SIG_IGN)

        let interruptSource = DispatchSource.makeSignalSource(
            signal: SIGINT,
            queue: queue
        )
        interruptSource.setEventHandler { [weak self] in
            self?.cancelAll()
        }
        self.interruptSource = interruptSource
        interruptSource.resume()

        let terminationSource = DispatchSource.makeSignalSource(
            signal: SIGTERM,
            queue: queue
        )
        terminationSource.setEventHandler { [weak self] in
            self?.cancelAll()
        }
        self.terminationSource = terminationSource
        terminationSource.resume()
    }

    private func uninstall() {
        interruptSource?.cancel()
        terminationSource?.cancel()
        interruptSource = nil
        terminationSource = nil
        _ = Darwin.signal(
            SIGINT,
            previousInterruptHandler ?? SIG_DFL
        )
        _ = Darwin.signal(
            SIGTERM,
            previousTerminationHandler ?? SIG_DFL
        )
        previousInterruptHandler = nil
        previousTerminationHandler = nil
    }

    private func cancelAll() {
        let callbacks = lock.withLock {
            Array(self.callbacks.values)
        }
        for callback in callbacks {
            callback()
        }
    }
}

private final class ProcessController: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var processIdentifier: Int32?
    private var ownsProcessGroup = false
    private var gracePeriod: TimeInterval = 0
    private var reason: ProcessTerminationReason?
    private var finished = false
    private var terminationStarted = false

    var requestedReason: ProcessTerminationReason? {
        lock.withLock { reason }
    }

    func register(
        process: Process,
        processIdentifier: Int32,
        ownsProcessGroup: Bool,
        gracePeriod: TimeInterval
    ) {
        let shouldTerminate = lock.withLock {
            self.process = process
            self.processIdentifier = processIdentifier
            self.ownsProcessGroup = ownsProcessGroup
            self.gracePeriod = gracePeriod
            guard reason != nil, !terminationStarted else { return false }
            terminationStarted = true
            return true
        }
        if shouldTerminate {
            terminateRegisteredProcess()
        }
    }

    func requestTermination(reason: ProcessTerminationReason) {
        let shouldTerminate = lock.withLock {
            guard !finished else { return false }
            guard self.reason == nil else { return false }
            self.reason = reason
            guard process != nil, !terminationStarted else { return false }
            terminationStarted = true
            return true
        }
        if shouldTerminate {
            terminateRegisteredProcess()
        }
    }

    func markFinished() {
        lock.withLock {
            finished = true
            process = nil
        }
    }

    private func terminateRegisteredProcess() {
        let state = lock.withLock {
            (
                process: process,
                processIdentifier: processIdentifier,
                ownsProcessGroup: ownsProcessGroup,
                gracePeriod: gracePeriod
            )
        }
        guard
            let process = state.process,
            let processIdentifier = state.processIdentifier,
            process.isRunning
        else {
            return
        }

        signal(
            SIGTERM,
            process: process,
            processIdentifier: processIdentifier,
            ownsProcessGroup: state.ownsProcessGroup
        )
        guard state.gracePeriod > 0 else {
            signal(
                SIGKILL,
                process: process,
                processIdentifier: processIdentifier,
                ownsProcessGroup: state.ownsProcessGroup
            )
            return
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + state.gracePeriod) {
            [weak self] in
            self?.killRegisteredProcess(
                processIdentifier: processIdentifier,
                ownsProcessGroup: state.ownsProcessGroup
            )
        }
    }

    private func killRegisteredProcess(
        processIdentifier: Int32,
        ownsProcessGroup: Bool
    ) {
        let process = lock.withLock {
            finished ? nil : self.process
        }
        guard let process, process.isRunning else { return }
        signal(
            SIGKILL,
            process: process,
            processIdentifier: processIdentifier,
            ownsProcessGroup: ownsProcessGroup
        )
    }

    private func signal(
        _ value: Int32,
        process: Process,
        processIdentifier: Int32,
        ownsProcessGroup: Bool
    ) {
        if ownsProcessGroup, getpgid(processIdentifier) == processIdentifier {
            _ = Darwin.kill(-processIdentifier, value)
        } else if value == SIGTERM {
            process.terminate()
        } else {
            _ = Darwin.kill(processIdentifier, value)
        }
    }
}

private final class ProcessPipeReaders: @unchecked Sendable {
    private let group = DispatchGroup()
    private let lock = NSLock()
    private let standardOutput: FileHandle
    private let standardError: FileHandle
    private let standardOutputCollector: ProcessLogCollector
    private let standardErrorCollector: ProcessLogCollector
    private var finishing = false

    init(
        standardOutput: FileHandle,
        standardError: FileHandle,
        standardOutputCollector: ProcessLogCollector,
        standardErrorCollector: ProcessLogCollector
    ) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.standardOutputCollector = standardOutputCollector
        self.standardErrorCollector = standardErrorCollector
    }

    func start() throws {
        try makeNonBlocking(standardOutput, name: "stdout pipe")
        try makeNonBlocking(standardError, name: "stderr pipe")
        read(standardOutput, into: standardOutputCollector)
        read(standardError, into: standardErrorCollector)
    }

    func finish() {
        lock.withLock {
            finishing = true
        }
        group.wait()
        try? standardOutput.close()
        try? standardError.close()
    }

    private func read(
        _ handle: FileHandle,
        into collector: ProcessLogCollector
    ) {
        group.enter()
        let group = group
        Thread.detachNewThread {
            defer { group.leave() }
            do {
                var buffer = [UInt8](repeating: 0, count: 65_536)
                while true {
                    let count = buffer.withUnsafeMutableBytes {
                        Darwin.read(
                            handle.fileDescriptor,
                            $0.baseAddress,
                            $0.count
                        )
                    }
                    if count > 0 {
                        try collector.consume(Data(buffer.prefix(count)))
                        continue
                    }
                    if count == 0 {
                        return
                    }
                    let code = errno
                    if code == EINTR {
                        continue
                    }
                    if code == EAGAIN || code == EWOULDBLOCK {
                        if self.lock.withLock({ self.finishing }) {
                            return
                        }
                        try self.waitUntilReadable(handle)
                        continue
                    }
                    throw ProcessLogError.systemCall(
                        operation: "read",
                        path: "process pipe",
                        code: code
                    )
                }
            } catch {
                collector.recordReadError(error)
            }
        }
    }

    private func makeNonBlocking(
        _ handle: FileHandle,
        name: String
    ) throws {
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags != -1 else {
            throw ProcessLogError.systemCall(
                operation: "fcntl(F_GETFL)",
                path: name,
                code: errno
            )
        }
        guard fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
            throw ProcessLogError.systemCall(
                operation: "fcntl(F_SETFL)",
                path: name,
                code: errno
            )
        }
    }

    private func waitUntilReadable(_ handle: FileHandle) throws {
        var descriptor = pollfd(
            fd: handle.fileDescriptor,
            events: Int16(POLLIN | POLLHUP | POLLERR),
            revents: 0
        )
        let result = Darwin.poll(&descriptor, 1, 100)
        guard result != -1 || errno == EINTR else {
            throw ProcessLogError.systemCall(
                operation: "poll",
                path: "process pipe",
                code: errno
            )
        }
    }
}

private final class ProcessLogCollector: @unchecked Sendable {
    struct Result {
        let data: Data
        let metadata: ProcessLogResult
    }

    private let lock = NSLock()
    private let url: URL
    private let reportedURL: URL?
    private let maximumCapturedBytes: Int
    private let maximumFileBytes: Int?
    private let handle: FileHandle
    private var captured = Data()
    private var writtenBytes = 0
    private var totalBytes = 0
    private var readError: Error?

    init(
        url: URL,
        reportedURL: URL?,
        maximumCapturedBytes: Int,
        maximumFileBytes: Int?
    ) throws {
        self.url = url
        self.reportedURL = reportedURL
        self.maximumCapturedBytes = maximumCapturedBytes
        self.maximumFileBytes = maximumFileBytes
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL,
            S_IRUSR | S_IWUSR
        )
        guard descriptor != -1 else {
            if errno == EEXIST {
                throw ProcessLogError.alreadyExists(url.path)
            }
            throw ProcessLogError.systemCall(
                operation: "open",
                path: url.path,
                code: errno
            )
        }
        handle = FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: true
        )
    }

    deinit {
        try? handle.close()
    }

    func discardCreatedLog() {
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }

    func consume(_ data: Data) throws {
        try lock.withLock {
            totalBytes += data.count
            retainTail(data)
            let writableCount =
                maximumFileBytes.map {
                    min(data.count, max(0, $0 - writtenBytes))
                } ?? data.count
            if writableCount > 0 {
                try handle.write(contentsOf: data.prefix(writableCount))
                writtenBytes += writableCount
            }
        }
    }

    func recordReadError(_ error: Error) {
        lock.withLock {
            readError = error
        }
    }

    func result() throws -> Result {
        try lock.withLock {
            if let readError {
                throw readError
            }
            try handle.synchronize()
            try handle.close()
            return Result(
                data: captured,
                metadata: ProcessLogResult(
                    url: reportedURL,
                    capturedBytes: captured.count,
                    writtenBytes: writtenBytes,
                    captureTruncated: totalBytes > captured.count,
                    fileTruncated: totalBytes > writtenBytes
                )
            )
        }
    }

    private func retainTail(_ data: Data) {
        guard maximumCapturedBytes > 0 else {
            captured.removeAll(keepingCapacity: false)
            return
        }
        captured.append(data)
        if captured.count > maximumCapturedBytes {
            captured.removeFirst(captured.count - maximumCapturedBytes)
        }
    }
}
