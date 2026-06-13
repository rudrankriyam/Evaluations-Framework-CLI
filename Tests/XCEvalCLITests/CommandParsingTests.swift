import Foundation
import Testing

@testable import XCEvalCLI

@Test("Subcommands own their output options")
func subcommandsOwnOutputOptions() throws {
    let command = try XCEvalRootCommand.parseAsRoot([
        "samples",
        "Result.xcevalresult",
        "--output",
        "jsonl"
    ])
    let samples = try #require(command as? SamplesCommand)

    #expect(samples.path == "Result.xcevalresult")
    #expect(samples.outputOptions.output == .jsonl)
}

@Test("Sample filters and collection selectors parse together")
func parsesSampleFilters() throws {
    let command = try XCEvalRootCommand.parseAsRoot([
        "samples",
        "Results.jsonl",
        "--result-id",
        "RESULT-2",
        "--metric",
        "Accuracy",
        "--kind",
        "fail",
        "--limit",
        "10"
    ])
    let samples = try #require(command as? SamplesCommand)

    #expect(samples.selection.resultID == "RESULT-2")
    #expect(samples.metric == "Accuracy")
    #expect(samples.kind == "fail")
    #expect(samples.limit == 10)
}

@Test("Run captures passthrough commands")
func parsesRunPassthrough() throws {
    let command = try XCEvalRootCommand.parseAsRoot([
        "run",
        "--results-path",
        "/tmp/results",
        "--",
        "swift",
        "run",
        "Evaluate"
    ])
    let run = try #require(command as? RunCommand)

    #expect(run.producerCommand == ["swift", "run", "Evaluate"])
}

@Test("Test command captures xcodebuild arguments")
func parsesTestPassthrough() throws {
    let command = try XCEvalRootCommand.parseAsRoot([
        "test",
        "--xcode",
        "/Applications/Xcode-beta.app",
        "--",
        "-scheme",
        "EvaluationTests",
        "test"
    ])
    let test = try #require(command as? TestCommand)

    #expect(
        test.xcodebuildArguments == [
            "-scheme",
            "EvaluationTests",
            "test"
        ])
}

@Test("Capabilities cover native, orchestrated, and producer-owned work")
func exposesCapabilityBoundaries() {
    let capabilities = CapabilitiesPayload(
        selectedXcode: nil
    ).capabilities

    #expect(capabilities.count == 13)
    #expect(capabilities.contains { $0.support == .native })
    #expect(capabilities.contains { $0.support == .orchestrated })
    #expect(capabilities.contains { $0.support == .producerOwned })
}

@Test("Artifact snapshots detect content changes with stable metadata")
func artifactSnapshotsHashContents() throws {
    let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("xceval-snapshot-\(UUID().uuidString).xcevalresult")
    defer { try? FileManager.default.removeItem(at: file) }
    let modificationDate = Date(timeIntervalSince1970: 1_700_000_000)

    try Data("AAAA".utf8).write(to: file)
    try FileManager.default.setAttributes(
        [.modificationDate: modificationDate],
        ofItemAtPath: file.path
    )
    let before = artifactSnapshot(at: file)

    try Data("BBBB".utf8).write(to: file)
    try FileManager.default.setAttributes(
        [.modificationDate: modificationDate],
        ofItemAtPath: file.path
    )
    let after = artifactSnapshot(at: file)

    #expect(before[file.path] != after[file.path])
}
