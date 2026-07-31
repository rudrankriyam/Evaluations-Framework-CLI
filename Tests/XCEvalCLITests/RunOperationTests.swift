import ArgumentParser
import Foundation
import Testing
import XCEvalCore

@testable import XCEvalCLI

@Test("Run semantic failures leave a terminal receipt with process logs")
func runSemanticFailureTerminalizesReceipt() async throws {
    let root = try temporaryRunDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    var command = try configuredRun(
        root: root,
        operationID: "semantic-failure",
        producerCommand: ["/usr/bin/true"]
    )

    do {
        try await command.run()
        Issue.record("Expected a run with no artifacts to fail.")
    } catch {}

    let receipt = try receipt(root: root, id: "semantic-failure")
    #expect(receipt.state == .failed)
    #expect(receipt.endedAt != nil)
    #expect(receipt.process?.status == 0)
    #expect(receipt.process?.terminationReason == .exited)
    #expect(receipt.errorMessage?.contains("no new or changed") == true)
    let stdout = try #require(receipt.process?.standardOutputLog)
    let stderr = try #require(receipt.process?.standardErrorLog)
    #expect(FileManager.default.fileExists(atPath: stdout))
    #expect(FileManager.default.fileExists(atPath: stderr))
}

@Test("Artifact load failures retain process evidence and do not stay running")
func artifactLoadFailureTerminalizesReceipt() async throws {
    let root = try temporaryRunDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let results = root.appendingPathComponent("results")
    let script = """
        mkdir -p "$1"
        printf 'not-json\n' > "$1/bad.xcevalresult"
        """
    var command = try configuredRun(
        root: root,
        operationID: "artifact-load-failure",
        producerCommand: ["/bin/sh", "-c", script, "sh", results.path]
    )

    do {
        try await command.run()
        Issue.record("Expected an invalid artifact to fail loading.")
    } catch {}

    let receipt = try receipt(root: root, id: "artifact-load-failure")
    #expect(receipt.state == .failed)
    #expect(receipt.endedAt != nil)
    #expect(receipt.process?.status == 0)
    #expect(receipt.process?.terminationReason == .exited)
    #expect(receipt.errorMessage != nil)
}

@Test("Selection validation fails before an operation is claimed")
func invalidSelectionDoesNotClaimOperation() async throws {
    let root = try temporaryRunDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let selection = root.appendingPathComponent("invalid.selection.json")
    try Data("not-json".utf8).write(to: selection)
    var command = try configuredRun(
        root: root,
        operationID: "invalid-selection",
        producerCommand: ["/usr/bin/true"],
        selection: selection
    )

    do {
        try await command.run()
        Issue.record("Expected invalid selection validation to fail.")
    } catch {}

    let store = operationStore(root: root)
    #expect(
        !FileManager.default.fileExists(
            atPath: store.receiptURL(
                for: "invalid-selection"
            ).path
        )
    )
}

@Test("An identical operation replay never re-executes its producer")
func identicalReplayDoesNotExecuteAgain() async throws {
    let root = try temporaryRunDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let marker = root.appendingPathComponent("marker")
    let results = root.appendingPathComponent("results")
    let script = """
        printf 'run\n' >> "$1"
        mkdir -p "$2"
        printf '%s\n' \
          '{"evaluationID":"Replay","resultID":"RESULT","results":[]}' \
          > "$2/result.xcevalresult"
        """
    let producer = [
        "/bin/sh",
        "-c",
        script,
        "sh",
        marker.path,
        results.path
    ]
    var first = try configuredRun(
        root: root,
        operationID: "replay",
        producerCommand: producer
    )
    try await first.run()
    let firstReceipt = try receipt(root: root, id: "replay")
    let stdoutPath = try #require(
        firstReceipt.process?.standardOutputLog
    )
    let stderrPath = try #require(
        firstReceipt.process?.standardErrorLog
    )
    let stdoutBeforeReplay = try Data(
        contentsOf: URL(fileURLWithPath: stdoutPath)
    )
    let stderrBeforeReplay = try Data(
        contentsOf: URL(fileURLWithPath: stderrPath)
    )

    var second = try configuredRun(
        root: root,
        operationID: "replay",
        producerCommand: producer
    )
    try await second.run()
    let replayedReceipt = try receipt(root: root, id: "replay")

    #expect(try String(contentsOf: marker, encoding: .utf8) == "run\n")
    #expect(replayedReceipt.operationID == firstReceipt.operationID)
    #expect(replayedReceipt.inputDigest == firstReceipt.inputDigest)
    #expect(replayedReceipt.state == .succeeded)
    #expect(
        try Data(contentsOf: URL(fileURLWithPath: stdoutPath))
            == stdoutBeforeReplay
    )
    #expect(
        try Data(contentsOf: URL(fileURLWithPath: stderrPath))
            == stderrBeforeReplay
    )
}

@Test("Orphaned deterministic logs fail without executing the producer")
func orphanedRunLogsFailClosed() async throws {
    let root = try temporaryRunDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let operationID = "orphaned-log"
    let operations = root.appendingPathComponent("operations")
    let logs = operations.appendingPathComponent("logs")
    try FileManager.default.createDirectory(
        at: logs,
        withIntermediateDirectories: true
    )
    let digest = ContentDigest(data: Data(operationID.utf8)).rawValue
    let stdout = logs.appendingPathComponent("\(digest).stdout.log")
    let original = Data("orphaned evidence\n".utf8)
    try original.write(to: stdout)
    let marker = root.appendingPathComponent("executed")
    var command = try configuredRun(
        root: root,
        operationID: operationID,
        producerCommand: ["/usr/bin/touch", marker.path]
    )

    do {
        try await command.run()
        Issue.record("Expected an orphaned log conflict.")
    } catch {}

    #expect(!FileManager.default.fileExists(atPath: marker.path))
    #expect(try Data(contentsOf: stdout) == original)
    let failed = try receipt(root: root, id: operationID)
    #expect(failed.state == .failed)
    #expect(failed.process == nil)
    #expect(failed.errorMessage?.contains("will not be replaced") == true)
}

@Test("Selection contents are part of the idempotent request identity")
func changedSelectionConflictsWithoutReexecution() async throws {
    let root = try temporaryRunDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let marker = root.appendingPathComponent("selection-marker")
    let results = root.appendingPathComponent("results")
    let selection = root.appendingPathComponent("selection.json")
    try selectionData(key: "case-a").write(to: selection)
    let script = """
        printf 'run\n' >> "$1"
        mkdir -p "$2"
        printf '%s\n' \
          '{"evaluationID":"Selection","resultID":"RESULT","results":[]}' \
          > "$2/result.xcevalresult"
        """
    let producer = [
        "/bin/sh",
        "-c",
        script,
        "sh",
        marker.path,
        results.path
    ]
    var first = try configuredRun(
        root: root,
        operationID: "selection-conflict",
        producerCommand: producer,
        selection: selection
    )
    try await first.run()

    try selectionData(key: "case-b").write(to: selection)
    var conflicting = try configuredRun(
        root: root,
        operationID: "selection-conflict",
        producerCommand: producer,
        selection: selection
    )
    do {
        try await conflicting.run()
        Issue.record("Expected changed selection contents to conflict.")
    } catch {}

    #expect(try String(contentsOf: marker, encoding: .utf8) == "run\n")
    #expect(
        try receipt(root: root, id: "selection-conflict").state == .succeeded
    )
}

@Test("Run timeout and task cancellation persist their distinct states")
func runPersistsTimeoutAndCancellation() async throws {
    let root = try temporaryRunDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    var timedOut = try configuredRun(
        root: root,
        operationID: "timeout",
        producerCommand: ["/bin/sleep", "30"],
        timeout: 0.05
    )
    do {
        try await timedOut.run()
        Issue.record("Expected the producer to time out.")
    } catch {}
    let timedOutReceipt = try receipt(root: root, id: "timeout")
    #expect(timedOutReceipt.state == .timedOut)
    #expect(timedOutReceipt.process?.terminationReason == .timedOut)

    let task = Task {
        var cancelled = try configuredRun(
            root: root,
            operationID: "cancelled",
            producerCommand: ["/bin/sleep", "30"]
        )
        try await cancelled.run()
    }
    try await Task.sleep(for: .milliseconds(100))
    task.cancel()
    do {
        try await task.value
        Issue.record("Expected the cancelled producer run to fail.")
    } catch {}
    let cancelledReceipt = try receipt(root: root, id: "cancelled")
    #expect(cancelledReceipt.state == .cancelled)
    #expect(cancelledReceipt.process?.terminationReason == .cancelled)
}

private func configuredRun(
    root: URL,
    operationID: String,
    producerCommand: [String],
    selection: URL? = nil,
    timeout: Double? = nil
) throws -> RunCommand {
    var arguments = [
        "run",
        "--results-path",
        root.appendingPathComponent("results").path,
        "--operation-id",
        operationID,
        "--state-directory",
        root.appendingPathComponent("operations").path,
        "--output",
        "text"
    ]
    if let selection {
        arguments += ["--selection", selection.path]
    }
    if let timeout {
        arguments += ["--timeout", String(timeout)]
    }
    arguments += ["--"] + producerCommand
    return try #require(
        try XCEvalRootCommand.parseAsRoot(arguments) as? RunCommand
    )
}

private func operationStore(root: URL) -> OperationReceiptStore {
    OperationReceiptStore(
        directory: root.appendingPathComponent("operations")
    )
}

private func receipt(root: URL, id: String) throws -> OperationReceipt {
    try operationStore(root: root).load(idempotencyKey: id)
}

private func temporaryRunDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "xceval-run-tests-\(UUID().uuidString)"
    )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    return root
}

private func selectionData(key: String) throws -> Data {
    try JSONSerialization.data(
        withJSONObject: [
            "schemaVersion": "xceval.selection/v1",
            "sampleKey": "/id",
            "count": 1,
            "samples": [
                [
                    "key": key,
                    "index": 0
                ]
            ]
        ],
        options: [.sortedKeys]
    )
}
