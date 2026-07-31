import Testing
import XCEvalCore

@testable import XCEvalCLI

@Test("Machine errors follow explicit and implicit JSON output resolution")
func machineErrorsFollowResolvedOutput() {
    #expect(shouldEmitMachineJSON(["list"], stdoutIsTerminal: false))
    #expect(!shouldEmitMachineJSON(["list"], stdoutIsTerminal: true))
    #expect(
        shouldEmitMachineJSON(
            ["list", "--output", "json"],
            stdoutIsTerminal: true
        )
    )
    #expect(
        !shouldEmitMachineJSON(
            ["list", "--output=text"],
            stdoutIsTerminal: false
        )
    )
    #expect(
        shouldEmitMachineJSON(
            ["run", "--output", "json", "--", "tool", "--output=text"],
            stdoutIsTerminal: true
        )
    )
    #expect(!shouldEmitMachineJSON(["--version"], stdoutIsTerminal: false))
    #expect(
        !shouldEmitMachineJSON(
            ["list", "--help"],
            stdoutIsTerminal: false
        )
    )
    #expect(
        shouldEmitMachineJSON(
            ["run", "--", "tool", "--help"],
            stdoutIsTerminal: false
        )
    )
}

@Test("A pending operation claim is a retryable in-progress signal")
func pendingOperationClaimIsRetryable() {
    let document = machineErrorDocument(
        error: OperationReceiptStoreError.claimPending("live-run"),
        arguments: ["run"]
    )

    #expect(document.command == "run")
    #expect(document.error.code == "operation_in_progress")
    #expect(document.error.retryable)
    #expect(document.error.details["operationID"] == .string("live-run"))
}

@Test("A missing operation receipt is distinct from a request conflict")
func missingOperationReceiptIsNotFound() {
    let document = machineErrorDocument(
        error: OperationReceiptStoreError.receiptNotFound("missing-run"),
        arguments: ["operation"]
    )

    #expect(document.command == "operation")
    #expect(document.error.code == "operation_not_found")
    #expect(!document.error.retryable)
    #expect(document.error.details["operationID"] == .string("missing-run"))
}

@Test("Operation receipt I/O failures are retryable state failures")
func operationReceiptIOFailureIsRetryable() {
    let document = machineErrorDocument(
        error: OperationReceiptStoreError.systemCall(
            operation: "open",
            code: 5
        ),
        arguments: ["operation"]
    )

    #expect(document.error.code == "operation_state_unavailable")
    #expect(document.error.retryable)
    #expect(document.error.details["operation"] == .string("open"))
    #expect(document.error.details["errno"] == .integer(5))
}
