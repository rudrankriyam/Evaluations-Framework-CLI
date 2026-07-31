import Foundation
import Testing

@testable import XCEvalCore

@Test("Process execution records exit metadata and bounded durable logs")
func processExecutionRecordsBoundedLogs() throws {
    let directory = temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let stdout = directory.appendingPathComponent("stdout.log")
    let stderr = directory.appendingPathComponent("stderr.log")
    let script = """
        index=0
        while [ "$index" -lt 40 ]; do
          printf 0123456789
          index=$((index + 1))
        done
        printf problem >&2
        """

    let result = try ProcessRunner.run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", script],
        options: ProcessExecutionOptions(
            logs: ProcessLogOptions(
                standardOutputURL: stdout,
                standardErrorURL: stderr,
                maximumCapturedBytes: 32,
                maximumFileBytes: 64
            )
        )
    )

    #expect(result.status == 0)
    #expect(result.terminationReason == .exited)
    #expect(result.terminationSignal == nil)
    #expect(result.duration >= 0)
    #expect(result.standardOutput.count == 32)
    #expect(result.standardOutputString == "89012345678901234567890123456789")
    #expect(result.standardErrorString == "problem")
    #expect(result.standardOutputLog.url == stdout)
    #expect(result.standardOutputLog.captureTruncated)
    #expect(result.standardOutputLog.fileTruncated)
    #expect(result.standardOutputLog.writtenBytes == 64)
    #expect((try Data(contentsOf: stdout)).count == 64)
}

@Test("Process execution never truncates pre-existing durable logs")
func processExecutionRejectsExistingLogs() throws {
    let directory = temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let stdout = directory.appendingPathComponent("stdout.log")
    let stderr = directory.appendingPathComponent("stderr.log")
    let marker = directory.appendingPathComponent("executed")
    let original = Data("existing evidence\n".utf8)
    try original.write(to: stderr)

    #expect(throws: ProcessLogError.alreadyExists(stderr.path)) {
        _ = try ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/touch"),
            arguments: [marker.path],
            options: ProcessExecutionOptions(
                logs: ProcessLogOptions(
                    standardOutputURL: stdout,
                    standardErrorURL: stderr
                )
            )
        )
    }
    #expect(!FileManager.default.fileExists(atPath: stdout.path))
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    #expect(try Data(contentsOf: stderr) == original)
}

@Test("Process timeout terminates the child and records a terminal reason")
func processTimeoutTerminatesChild() throws {
    let result = try ProcessRunner.run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "printf ready; sleep 30"],
        options: ProcessExecutionOptions(
            timeout: 0.1,
            terminationGracePeriod: 0
        )
    )

    #expect(result.terminationReason == .timedOut)
    #expect(result.status != 0)
    #expect(result.duration < 5)
    #expect(result.standardOutputString == "ready")
}

@Test("Cancelling an asynchronous run terminates the child")
func processTaskCancellationTerminatesChild() async throws {
    let directory = temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let started = directory.appendingPathComponent("started")
    var environment = ProcessInfo.processInfo.environment
    environment["XCEVAL_PROCESS_STARTED"] = started.path
    let task = Task {
        try await ProcessRunner.runAsync(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "printf started; touch \"$XCEVAL_PROCESS_STARTED\"; sleep 30"
            ],
            environment: environment,
            options: ProcessExecutionOptions(
                terminationGracePeriod: 0
            )
        )
    }
    for _ in 0..<500
    where !FileManager.default.fileExists(atPath: started.path) {
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(
        FileManager.default.fileExists(atPath: started.path),
        "The child did not start within five seconds."
    )
    task.cancel()
    let result = try await task.value

    #expect(result.terminationReason == .cancelled)
    #expect(result.status != 0)
    #expect(result.duration < 5)
    #expect(result.standardOutputString == "started")
}

@Test("Process completion is not blocked by a detached descendant's pipe")
func processCompletionIgnoresDetachedDescendantPipe() throws {
    let result = try ProcessRunner.run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [
            "-c",
            "sleep 30 & printf '%s' \"$!\" >&2; printf complete"
        ]
    )
    let childPID = try #require(Int32(result.standardErrorString))
    defer { _ = Darwin.kill(childPID, SIGKILL) }

    #expect(result.terminationReason == .exited)
    #expect(result.status == 0)
    #expect(result.duration < 5)
    #expect(result.standardOutputString == "complete")
}

@Test("Operation receipt claims are idempotent across concurrent callers")
func operationReceiptClaimsAreIdempotent() async throws {
    let directory = temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = OperationReceiptStore(directory: directory)
    let receipt = OperationReceipt(
        idempotencyKey: "dataset-17:prompt-a",
        operation: "evaluation.run",
        startedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    guard case .claimed(_, let lease) = try store.claim(receipt) else {
        Issue.record("Expected the first receipt claim to succeed.")
        return
    }
    defer { lease.release() }

    let claimedCount = try await withThrowingTaskGroup(
        of: Bool.self,
        returning: Int.self
    ) { group in
        for _ in 0..<8 {
            group.addTask {
                switch try store.claim(receipt) {
                case .claimed:
                    true
                case .existing:
                    false
                }
            }
        }
        var claimedCount = 0
        for try await claimed in group where claimed {
            claimedCount += 1
        }
        return claimedCount
    }

    #expect(claimedCount == 0)
    let persisted = try store.load(idempotencyKey: receipt.idempotencyKey)
    #expect(persisted.operationID == receipt.operationID)
    #expect(persisted.state == .running)
    #expect(persisted.attempt == 1)
}

@Test("An abandoned running receipt is recovered as the next attempt")
func operationReceiptRecoversAbandonedAttempt() throws {
    let directory = temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = OperationReceiptStore(directory: directory)
    let first = OperationReceipt(
        idempotencyKey: "recover-after-crash",
        operation: "evaluation.run",
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        inputDigest: "sha256:request"
    )
    guard
        case .claimed(let claimed, let abandonedLease) =
            try store.claim(first)
    else {
        Issue.record("Expected the first receipt claim to succeed.")
        return
    }
    abandonedLease.release()

    let retry = OperationReceipt(
        idempotencyKey: first.idempotencyKey,
        operation: first.operation,
        startedAt: Date(timeIntervalSince1970: 1_700_000_100),
        inputDigest: first.inputDigest
    )
    guard
        case .claimed(let recovered, let retryLease) =
            try store.claim(retry)
    else {
        Issue.record("Expected the abandoned receipt to be recovered.")
        return
    }
    defer { retryLease.release() }

    #expect(recovered.operationID == claimed.operationID)
    #expect(recovered.attempt == 2)
    #expect(recovered.state == .running)
    #expect(recovered.startedAt == retry.startedAt)
    #expect(recovered.inputDigest == first.inputDigest)
    #expect(recovered.process == nil)
    #expect(recovered.outputs.isEmpty)
}

@Test("Operation receipts update atomically and terminal states are immutable")
func operationReceiptsBecomeImmutableAtTerminalState() throws {
    let directory = temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = OperationReceiptStore(directory: directory)
    let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let receipt = OperationReceipt(
        idempotencyKey: "stable-key",
        operation: "xcodebuild.test",
        startedAt: startedAt
    )
    guard case .claimed(let claimed, let lease) = try store.claim(receipt) else {
        Issue.record("Expected the first receipt claim to succeed.")
        return
    }
    defer { lease.release() }
    let result = try ProcessRunner.run(
        executable: URL(fileURLWithPath: "/usr/bin/true"),
        arguments: []
    )
    let completed = claimed.completing(
        with: result,
        outputs: [
            OperationOutputArtifact(
                path: "/tmp/Tests.xcresult",
                contentDigest: "abc123"
            )
        ],
        endedAt: Date(timeIntervalSince1970: 1_700_000_001)
    )

    try store.save(completed)
    let persisted = try store.load(idempotencyKey: receipt.idempotencyKey)
    #expect(persisted.state == .succeeded)
    #expect(persisted.endedAt == Date(timeIntervalSince1970: 1_700_000_001))
    #expect(persisted.outputs == completed.outputs)
    #expect(throws: OperationReceiptStoreError.terminalReceiptImmutable) {
        try store.save(completed)
    }
}

@Test("Operation receipt storage rejects contradictory terminal evidence")
func operationReceiptRejectsContradictoryEvidence() throws {
    let directory = temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = OperationReceiptStore(directory: directory)
    let invalid = OperationReceipt(
        idempotencyKey: "invalid-timeout",
        operation: "evaluation.run",
        state: .timedOut,
        endedAt: Date()
    )

    #expect(throws: OperationReceiptStoreError.invalidLifecycleEvidence) {
        try store.claim(invalid)
    }
    #expect(
        !FileManager.default.fileExists(
            atPath: store.receiptURL(
                for: invalid.idempotencyKey
            ).path
        )
    )
}

private func temporaryTestDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
        "xceval-core-tests-\(UUID().uuidString)"
    )
}
