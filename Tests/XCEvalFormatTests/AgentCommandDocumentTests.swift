import Foundation
import Testing
import XCEvalFormat

@Test("Machine error schema takes precedence over the failed command name")
func decodesMachineErrorDocument() throws {
    let document = try XCEvalDocumentDecoder.decode(
        agentJSON(
            """
            {
              "schemaVersion":"xceval.error/v1",
              "command":"run",
              "error":{
                "code":"operation_conflict",
                "message":"The operation is already pending.",
                "retryable":true,
                "details":{"operationID":"candidate-1"}
              }
            }
            """
        )
    )
    guard case .error(let error) = document else {
        Issue.record("Expected an error document.")
        return
    }

    #expect(error.command == "run")
    #expect(error.error.code == "operation_conflict")
    #expect(error.error.retryable)
    #expect(error.error.details["operationID"] == .string("candidate-1"))
}

@Test("Operation receipts decode without a command envelope")
func decodesOperationReceipt() throws {
    let document = try XCEvalDocumentDecoder.decode(
        agentJSON(operationReceipt)
    )
    guard case .operation(let receipt) = document else {
        Issue.record("Expected an operation receipt.")
        return
    }

    #expect(receipt.idempotencyKey == "candidate-1")
    #expect(receipt.state == .timedOut)
    #expect(receipt.process?.terminationReason == .timedOut)
    #expect(receipt.process?.standardErrorTruncated == true)
    #expect(receipt.outputs.first?.contentDigest == "sha256:abc")
}

@Test("Result-derived selections decode through their existing schema")
func decodesSelectionDocument() throws {
    let document = try XCEvalDocumentDecoder.decode(
        agentJSON(
            """
            {
              "schemaVersion":"xceval.selection/v1",
              "command":"select",
              "source":\(agentArtifactIdentity),
              "sampleKey":"/id",
              "count":1,
              "samples":[{
                "key":"sample-1",
                "canonicalKey":"\\"sample-1\\"",
                "index":0,
                "input":{"id":"sample-1"},
                "inputDigest":"sha256:def"
              }],
              "outputPath":"/tmp/selection.json"
            }
            """
        )
    )
    guard case .selection(let selection) = document else {
        Issue.record("Expected a selection document.")
        return
    }

    #expect(selection.count == 1)
    #expect(selection.samples.first?.canonicalKey == #""sample-1""#)
    #expect(selection.samples.first?.input?["id"] == .string("sample-1"))
}

@Test("Nested dataset discovery and validation documents decode")
func decodesDatasetReadDocuments() throws {
    let discover = try XCEvalDocumentDecoder.decode(
        agentJSON(
            """
            {
              "schemaVersion":"xceval.datasets/v1",
              "command":"datasets.discover",
              "count":2,
              "datasets":[{
                "path":"/tmp/dataset.json",
                "format":"json",
                "recordCount":3,
                "datasetID":"sha256:dataset"
              },{
                "path":"/tmp/broken.jsonl",
                "loadError":"The file is not valid dataset JSON or JSONL."
              }]
            }
            """
        )
    )
    guard case .datasetsDiscover(let discovered) = discover else {
        Issue.record("Expected a datasets discover document.")
        return
    }
    #expect(discovered.count == 2)
    #expect(discovered.datasets.last?.recordCount == nil)
    #expect(discovered.datasets.last?.loadError != nil)

    let validate = try XCEvalDocumentDecoder.decode(
        agentJSON(
            """
            {
              "schemaVersion":"xceval.dataset-validation/v1",
              "command":"datasets.validate",
              "path":"/tmp/dataset.json",
              "datasetID":"sha256:dataset",
              "recordCount":3,
              "valid":false,
              "issues":[{
                "code":"duplicate_sample_key",
                "recordIndex":2,
                "message":"The sample key is duplicated."
              }]
            }
            """
        )
    )
    guard case .datasetsValidate(let validation) = validate else {
        Issue.record("Expected a datasets validate document.")
        return
    }
    #expect(validation.valid == false)
    #expect(validation.issues.first?.recordIndex == 2)
}

@Test("Nested dataset mutation documents decode")
func decodesDatasetMutationDocuments() throws {
    let select = try XCEvalDocumentDecoder.decode(
        agentJSON(
            """
            {
              "schemaVersion":"xceval.datasets/v1",
              "command":"datasets.select",
              "sourcePath":"/tmp/dataset.json",
              "datasetID":"sha256:dataset",
              "selectedCount":2,
              "missingKeys":["missing"],
              "outputPath":"/tmp/selected.json"
            }
            """
        )
    )
    guard case .datasetsSelect(let selection) = select else {
        Issue.record("Expected a datasets select document.")
        return
    }
    #expect(selection.selectedCount == 2)
    #expect(selection.missingKeys == ["missing"])

    let draft = try XCEvalDocumentDecoder.decode(
        agentJSON(
            """
            {
              "schemaVersion":"xceval.datasets/v1",
              "command":"datasets.draft",
              "source":\(agentArtifactIdentity),
              "recordCount":4,
              "outputPath":"/tmp/draft.json"
            }
            """
        )
    )
    guard case .datasetsDraft(let drafted) = draft else {
        Issue.record("Expected a datasets draft document.")
        return
    }
    #expect(drafted.source.resultID == "RESULT-1")
    #expect(drafted.recordCount == 4)

    let promote = try XCEvalDocumentDecoder.decode(
        agentJSON(
            """
            {
              "schemaVersion":"xceval.datasets/v1",
              "command":"datasets.promote",
              "sourcePath":"/tmp/dataset.json",
              "draftPath":"/tmp/draft.json",
              "datasetID":"sha256:promoted",
              "addedCount":3,
              "duplicateCount":1,
              "outputPath":"/tmp/promoted.json"
            }
            """
        )
    )
    guard case .datasetsPromote(let promoted) = promote else {
        Issue.record("Expected a datasets promote document.")
        return
    }
    #expect(promoted.addedCount == 3)
    #expect(promoted.duplicateCount == 1)
}

@Test("Run documents decode additive process and operation fields")
func decodesExpandedRunDocument() throws {
    let document = try XCEvalDocumentDecoder.decode(
        agentJSON(
            """
            {
              "schemaVersion":"xceval/v1",
              "command":"run",
              "producerCommand":["swift","run","Evaluate"],
              "workingDirectory":"/tmp/project",
              "resultsPath":"/tmp/project/results",
              "process":\(agentProcess),
              "artifacts":[],
              "operationReceipt":\(operationReceipt),
              "errorMessage":"The producer timed out.",
              "replayed":true
            }
            """
        )
    )
    guard case .run(let run) = document else {
        Issue.record("Expected a run document.")
        return
    }

    #expect(run.process?.terminationReason == .timedOut)
    #expect(run.process?.duration == 30)
    #expect(run.process?.standardOutputTruncated == false)
    #expect(run.operationReceipt?.state == .timedOut)
    #expect(run.errorMessage == "The producer timed out.")
    #expect(run.replayed == true)
}

@Test("Run documents represent a live idempotent observer")
func decodesInProgressRunDocument() throws {
    let document = try XCEvalDocumentDecoder.decode(
        agentJSON(
            """
            {
              "schemaVersion":"xceval/v1",
              "command":"run",
              "producerCommand":["swift","run","Evaluate"],
              "resultsPath":"/tmp/project/results",
              "artifacts":[],
              "operationReceipt":{
                "schemaVersion":"xceval.operation-receipt/v1",
                "operationID":"00000000-0000-0000-0000-000000000001",
                "idempotencyKey":"candidate-1",
                "operation":"run",
                "attempt":1,
                "state":"running",
                "startedAt":0,
                "outputs":[]
              },
              "replayed":true
            }
            """
        )
    )
    guard case .run(let run) = document else {
        Issue.record("Expected an in-progress run document.")
        return
    }

    #expect(run.process == nil)
    #expect(run.artifacts.isEmpty)
    #expect(run.operationReceipt?.state == .running)
    #expect(run.replayed == true)
}

private func agentJSON(_ value: String) -> Data {
    Data(value.utf8)
}

private let agentArtifactIdentity =
    #"{"path":"/tmp/Result.xcevalresult","evaluationID":"BookSearch","resultID":"RESULT-1"}"#

private let agentProcess =
    #"{"status":124,"terminationReason":"timedOut","terminationSignal":15,"duration":30,"processIdentifier":42,"processGroupIdentifier":42,"standardOutput":"","standardError":"timed out","standardOutputLog":"/tmp/stdout.log","standardErrorLog":"/tmp/stderr.log","standardOutputTruncated":false,"standardErrorTruncated":true}"#

private let operationReceipt =
    #"{"schemaVersion":"xceval.operation-receipt/v1","operationID":"00000000-0000-0000-0000-000000000001","idempotencyKey":"candidate-1","operation":"run","attempt":1,"state":"timedOut","startedAt":0,"endedAt":30,"inputDigest":"sha256:input","process":{"status":124,"terminationReason":"timedOut","terminationSignal":15,"duration":30,"processIdentifier":42,"processGroupIdentifier":42,"standardOutputLog":"/tmp/stdout.log","standardErrorLog":"/tmp/stderr.log","standardOutputTruncated":false,"standardErrorTruncated":true},"outputs":[{"path":"/tmp/result.xcevalresult","contentDigest":"sha256:abc"}],"errorMessage":"The producer timed out."}"#
