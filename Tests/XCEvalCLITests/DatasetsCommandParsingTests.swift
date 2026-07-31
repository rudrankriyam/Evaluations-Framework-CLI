import Foundation
import Testing
import XCEvalCore
import XCEvalFormat

@testable import XCEvalCLI

@Test("Dataset selection exposes strict lifecycle identity controls")
func parsesDatasetSelectionLifecycleOptions() throws {
    let command = try XCEvalRootCommand.parseAsRoot([
        "datasets",
        "select",
        "suite.dataset.json",
        "--selection",
        "selection.json",
        "--sample-key",
        "/id",
        "--dataset-id",
        "suite",
        "--allow-missing",
        "--output-path",
        "selected.json"
    ])
    let select = try #require(command as? DatasetsSelectCommand)

    #expect(select.logicalDatasetID == "suite")
    #expect(select.allowMissing)
}

@Test("Dataset drafting exposes a durable rejected-candidate quarantine")
func parsesDatasetDraftQuarantinePath() throws {
    let command = try XCEvalRootCommand.parseAsRoot([
        "datasets",
        "draft",
        "Result.xcevalresult",
        "--sample-key",
        "/input/id",
        "--output-path",
        "draft.json",
        "--quarantine-path",
        "draft.quarantine.json"
    ])
    let draft = try #require(command as? DatasetsDraftCommand)

    #expect(draft.quarantinePath == "draft.quarantine.json")
}

@Test("Dataset promotion exposes optimistic concurrency")
func parsesDatasetPromotionBaseDigest() throws {
    let digest = String(repeating: "a", count: 64)
    let command = try XCEvalRootCommand.parseAsRoot([
        "datasets",
        "promote",
        "draft.json",
        "--into",
        "suite.dataset.json",
        "--sample-key",
        "/id",
        "--expected-base-digest",
        "sha256:\(digest)",
        "--output-path",
        "promoted.json"
    ])
    let promote = try #require(command as? DatasetsPromoteCommand)

    #expect(promote.expectedBaseDigest == "sha256:\(digest)")
}

@Test("Dataset drafting persists unkeyed candidates in quarantine")
func datasetDraftRetainsRejectedCandidate() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "xceval-dataset-draft-\(UUID().uuidString)",
            isDirectory: true
        )
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let artifact = directory.appendingPathComponent("result.xcevalresult")
    let draftPath = directory.appendingPathComponent("draft.json")
    let quarantinePath = directory.appendingPathComponent("quarantine.json")
    let artifactValue: JSONValue = .object([
        "evaluationID": .string("suite"),
        "resultID": .string("run-1"),
        "results": .array([
            .object([
                "Expected": .string("answer"),
                "Input": .string(#"{"input":{"name":"missing-id"}}"#),
                "Response": .object([
                    "typeName": .string("String"),
                    "value": .string("answer")
                ])
            ])
        ])
    ])
    try artifactValue.encodedData(pretty: true).write(to: artifact)

    var command = try #require(
        try XCEvalRootCommand.parseAsRoot([
            "datasets",
            "draft",
            artifact.path,
            "--sample-key",
            "/input/id",
            "--output-path",
            draftPath.path,
            "--quarantine-path",
            quarantinePath.path
        ]) as? DatasetsDraftCommand
    )
    try command.run()

    let draft = try JSONValue.decode(Data(contentsOf: draftPath))
    #expect(draft.arrayValue == [])
    let quarantine = try JSONDecoder().decode(
        EvaluationDatasetQuarantine.self,
        from: Data(contentsOf: quarantinePath)
    )
    #expect(quarantine.accepted.isEmpty)
    #expect(quarantine.rejected.count == 1)
    #expect(
        quarantine.rejected[0].reasons
            == ["Stable sample key /input/id is missing."]
    )
}
