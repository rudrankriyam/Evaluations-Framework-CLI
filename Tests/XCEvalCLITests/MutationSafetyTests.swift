import Foundation
import Testing
import XCEvalCore

@testable import XCEvalCLI

@Test("Selection rejects duplicate sample keys before writing a manifest")
func selectionRejectsDuplicateKeysBeforeWriting() throws {
    let root = try mutationSafetyDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("duplicate.xcevalresult")
    try Data(
        #"""
        {
          "evaluationID": "DuplicateKeys",
          "resultID": "R",
          "results": [
            {
              "Input": "{\"input\":{\"id\":\"shared\",\"prompt\":\"First\"}}"
            },
            {
              "Input": "{\"input\":{\"id\":\"shared\",\"prompt\":\"Second\"}}"
            }
          ]
        }
        """#.utf8
    ).write(to: source)
    let destination = root.appendingPathComponent("selection.json")
    var command = try #require(
        try XCEvalRootCommand.parseAsRoot([
            "select",
            source.path,
            "--sample-key",
            "/input/id",
            "--output-path",
            destination.path,
            "--output",
            "text"
        ]) as? SelectCommand
    )

    do {
        try command.run()
        Issue.record("Expected duplicate selection keys to fail.")
    } catch {
        #expect(
            userFacingErrorMessage(error).contains(
                "shared at indices 0, 1"
            )
        )
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
}

@Test("Selection force cannot replace its source artifact")
func selectionProtectsItsSource() throws {
    let root = try mutationSafetyDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("result.xcevalresult")
    let original = Data(
        #"{"evaluationID":"Safe","resultID":"R","results":[]}"#.utf8
    )
    try original.write(to: source)
    var command = try #require(
        try XCEvalRootCommand.parseAsRoot([
            "select",
            source.path,
            "--output-path",
            source.path,
            "--force",
            "--output",
            "text"
        ]) as? SelectCommand
    )

    #expect(throws: DestructivePathError.self) {
        try command.run()
    }
    #expect(try Data(contentsOf: source) == original)
}

@Test("Dataset selection force cannot replace either input")
func datasetSelectionProtectsInputs() throws {
    let root = try mutationSafetyDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let dataset = root.appendingPathComponent("dataset.json")
    let selection = root.appendingPathComponent("selection.json")
    let original = Data("[]\n".utf8)
    try original.write(to: dataset)
    try Data(#"{"samples":[]}"#.utf8).write(to: selection)
    var command = try #require(
        try XCEvalRootCommand.parseAsRoot([
            "datasets",
            "select",
            dataset.path,
            "--selection",
            selection.path,
            "--sample-key",
            "/id",
            "--output-path",
            dataset.path,
            "--force",
            "--output",
            "text"
        ]) as? DatasetsSelectCommand
    )

    #expect(throws: DestructivePathError.self) {
        try command.run()
    }
    #expect(try Data(contentsOf: dataset) == original)
}

@Test("Dataset draft validates both outputs before writing")
func datasetDraftRejectsOverlappingOutputs() throws {
    let root = try mutationSafetyDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("result.xcevalresult")
    try Data(
        #"{"evaluationID":"Safe","resultID":"R","results":[]}"#.utf8
    ).write(to: source)
    let draft = root.appendingPathComponent("draft.json")
    let quarantine = draft.appendingPathComponent("quarantine.json")
    var command = try #require(
        try XCEvalRootCommand.parseAsRoot([
            "datasets",
            "draft",
            source.path,
            "--sample-key",
            "/id",
            "--output-path",
            draft.path,
            "--quarantine-path",
            quarantine.path,
            "--force",
            "--output",
            "text"
        ]) as? DatasetsDraftCommand
    )

    #expect(throws: DestructivePathError.self) {
        try command.run()
    }
    #expect(!FileManager.default.fileExists(atPath: draft.path))
    #expect(!FileManager.default.fileExists(atPath: quarantine.path))
}

@Test("Dataset promotion force cannot replace a source dataset")
func datasetPromotionProtectsInputs() throws {
    let root = try mutationSafetyDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let base = root.appendingPathComponent("base.json")
    let draft = root.appendingPathComponent("draft.json")
    let original = Data("[]\n".utf8)
    try original.write(to: base)
    try Data("[]\n".utf8).write(to: draft)
    var command = try #require(
        try XCEvalRootCommand.parseAsRoot([
            "datasets",
            "promote",
            draft.path,
            "--into",
            base.path,
            "--sample-key",
            "/id",
            "--output-path",
            base.path,
            "--force",
            "--output",
            "text"
        ]) as? DatasetsPromoteCommand
    )

    #expect(throws: DestructivePathError.self) {
        try command.run()
    }
    #expect(try Data(contentsOf: base) == original)
}

private func mutationSafetyDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "xceval-mutation-safety-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    return root
}
