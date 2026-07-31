import ArgumentParser
import Foundation
import XCEvalCore
import XCEvalFormat

struct XCEvalMachineErrorDocument: Encodable {
    let schemaVersion = "xceval.error/v1"
    let command: String
    let error: XCEvalMachineErrorBody
}

struct XCEvalMachineErrorBody: Encodable {
    let code: String
    let message: String
    let retryable: Bool
    let details: [String: JSONValue]
}

enum XCEvalCLIError: LocalizedError {
    case manifestNotFound(path: String)
    case operationConflict(operationID: String)
    case operationEvidenceUnavailable(
        operationID: String,
        component: String
    )

    var errorDescription: String? {
        switch self {
        case .manifestNotFound(let path):
            "The target manifest does not exist: \(path)"
        case .operationConflict(let operationID):
            "Operation ID '\(operationID)' is already bound to a different "
                + "run request."
        case .operationEvidenceUnavailable(let operationID, let component):
            "Operation '\(operationID)' cannot reconstruct its run response "
                + "because \(component) is unavailable."
        }
    }
}

func machineErrorDocument(
    error: Error,
    arguments: [String]
) -> XCEvalMachineErrorDocument {
    let command =
        arguments.first(where: { !$0.hasPrefix("-") })
        ?? "xceval"
    let classified = classifyMachineError(error)
    return XCEvalMachineErrorDocument(
        command: command,
        error: XCEvalMachineErrorBody(
            code: classified.code,
            message: userFacingErrorMessage(error),
            retryable: classified.retryable,
            details: classified.details
        )
    )
}

func userFacingErrorMessage(_ error: Error) -> String {
    if let validationError = error as? ValidationError {
        return validationError.description
    }
    return error.localizedDescription
}

private func classifyMachineError(
    _ error: Error
) -> (
    code: String,
    retryable: Bool,
    details: [String: JSONValue]
) {
    if error is ValidationError {
        return ("invalid_arguments", false, [:])
    }
    if let error = error as? XCEvalCLIError {
        switch error {
        case .manifestNotFound(let path):
            return (
                "manifest_not_found",
                false,
                ["path": .string(path)]
            )
        case .operationConflict(let operationID):
            return (
                "operation_conflict",
                false,
                ["operationID": .string(operationID)]
            )
        case .operationEvidenceUnavailable(let operationID, let component):
            return (
                "operation_evidence_unavailable",
                false,
                [
                    "operationID": .string(operationID),
                    "component": .string(component)
                ]
            )
        }
    }
    if let error = error as? EvaluationArtifactLoaderError {
        switch error {
        case .pathDoesNotExist(let path):
            return (
                "input_not_found",
                false,
                ["path": .string(path)]
            )
        case .cannotEnumerate(let path):
            return (
                "input_unreadable",
                true,
                ["path": .string(path)]
            )
        case .invalidJSONLine(let source, let line, _):
            return (
                "artifact_invalid",
                false,
                [
                    "path": .string(source),
                    "line": .integer(Int64(line))
                ]
            )
        case .noArtifacts(let path):
            return (
                "artifact_not_found",
                false,
                ["path": .string(path)]
            )
        }
    }
    if let error = error as? EvaluationTargetManifestError {
        switch error {
        case .targetNotFound(let id):
            return (
                "target_not_found",
                false,
                ["targetID": .string(id)]
            )
        default:
            return ("manifest_invalid", false, [:])
        }
    }
    if let error = error as? DestructivePathError {
        return (
            "unsafe_output_path",
            false,
            ["path": .string(destructiveTargetPath(error))]
        )
    }
    if let error = error as? OperationReceiptStoreError {
        switch error {
        case .receiptNotFound(let operationID):
            return (
                "operation_not_found",
                false,
                ["operationID": .string(operationID)]
            )
        case .claimPending(let operationID):
            return (
                "operation_in_progress",
                true,
                ["operationID": .string(operationID)]
            )
        case .executionOutcomeAmbiguous(let operationID):
            return (
                "operation_outcome_ambiguous",
                false,
                ["operationID": .string(operationID)]
            )
        case .idempotencyKeyMismatch,
            .receiptIdentityMismatch,
            .terminalReceiptImmutable:
            return ("operation_conflict", false, [:])
        case .emptyIdempotencyKey, .emptyOperation,
            .invalidTerminalState, .invalidLifecycleEvidence:
            return ("operation_state_invalid", false, [:])
        case .unsupportedSchema(let schemaVersion):
            return (
                "operation_state_invalid",
                false,
                ["schemaVersion": .string(schemaVersion)]
            )
        case .systemCall(let operation, let code):
            return (
                "operation_state_unavailable",
                true,
                [
                    "operation": .string(operation),
                    "errno": .integer(Int64(code))
                ]
            )
        }
    }
    return ("command_failed", false, [:])
}

private func destructiveTargetPath(_ error: DestructivePathError) -> String {
    switch error {
    case .broadAllowedRoot(let path), .broadTarget(let path):
        path
    case .outsideAllowedRoot(let path, _):
        path
    case .protectedPathOverlap(let path, _):
        path
    case .overlappingTargets(let path, _):
        path
    case .emptyTargets:
        ""
    }
}
