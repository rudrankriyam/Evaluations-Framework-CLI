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

    var errorDescription: String? {
        switch self {
        case .manifestNotFound(let path):
            "The target manifest does not exist: \(path)"
        case .operationConflict(let operationID):
            "Operation ID '\(operationID)' is already bound to a different "
                + "run request."
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
        return (
            "operation_conflict",
            error.localizedDescription.contains("pending"),
            [:]
        )
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
