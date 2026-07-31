import Foundation
import Testing
import XCEvalCore

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

@Test("Report accepts a baseline and artifact selection")
func parsesReportOptions() throws {
    let command = try XCEvalRootCommand.parseAsRoot([
        "report",
        "results.jsonl",
        "--result-id",
        "CANDIDATE",
        "--baseline",
        "baseline.xcevalresult",
        "--output",
        "json"
    ])
    let report = try #require(command as? ReportCommand)

    #expect(report.selection.resultID == "CANDIDATE")
    #expect(report.baseline == "baseline.xcevalresult")
}

@Test("Pipeline parses variables and Xcode overrides")
func parsesPipelineOptions() throws {
    let command = try XCEvalRootCommand.parseAsRoot([
        "pipeline",
        "custom.pipeline.json",
        "--set",
        "RUN=result.json",
        "--xcode",
        "/Applications/Xcode-beta.app",
        "--force"
    ])
    let pipeline = try #require(command as? PipelineCommand)

    #expect(pipeline.manifestPath == "custom.pipeline.json")
    #expect(pipeline.assignments == ["RUN=result.json"])
    #expect(pipeline.xcode == "/Applications/Xcode-beta.app")
    #expect(pipeline.force)
}

@Test("Init parses a custom destination")
func parsesInitOptions() throws {
    let command = try XCEvalRootCommand.parseAsRoot([
        "init",
        "Search Quality",
        "--path",
        "/tmp/SearchQualityEvaluations"
    ])
    let initializer = try #require(command as? InitCommand)

    #expect(initializer.name == "Search Quality")
    #expect(initializer.path == "/tmp/SearchQualityEvaluations")
}

@Test("Init parses an explicit authoring template")
func parsesInitAuthoringTemplate() throws {
    let command = try XCEvalRootCommand.parseAsRoot([
        "init",
        "Search Quality",
        "--template",
        "tool-call"
    ])
    let initializer = try #require(command as? InitCommand)

    #expect(initializer.template == .toolCall)
}

@Test("API commands parse exact symbols, recipes, and Xcode selection")
func parsesAPICommands() throws {
    let list = try #require(
        try XCEvalRootCommand.parseAsRoot([
            "api",
            "list",
            "--xcode",
            "/Applications/Xcode-beta.app",
            "--output",
            "json"
        ]) as? ApiListCommand
    )
    #expect(list.xcode == "/Applications/Xcode-beta.app")
    #expect(list.outputOptions.output == .json)

    let show = try #require(
        try XCEvalRootCommand.parseAsRoot([
            "api",
            "show",
            "Evaluations.ToolCallEvaluator"
        ]) as? ApiShowCommand
    )
    #expect(show.symbol == "Evaluations.ToolCallEvaluator")

    let example = try #require(
        try XCEvalRootCommand.parseAsRoot([
            "api",
            "example",
            "model-judge",
            "--type-name",
            "MyJudgeEvaluation"
        ]) as? ApiExampleCommand
    )
    #expect(example.kind == .modelJudge)
    #expect(example.typeName == "MyJudgeEvaluation")

    let verify = try #require(
        try XCEvalRootCommand.parseAsRoot([
            "api",
            "verify",
            "synthetic",
            "--xcode",
            "/Applications/Xcode-beta.app"
        ]) as? ApiVerifyCommand
    )
    #expect(verify.kind == .synthetic)
    #expect(verify.xcode == "/Applications/Xcode-beta.app")
}

@Test("API payloads expose stable command schemas")
func encodesAPIPayloadSchemas() throws {
    let source = EvaluationsAPISource(
        frameworkPath: "/Xcode/Evaluations.framework",
        interfacePath: "/Xcode/Evaluations.swiftinterface",
        architecture: "arm64"
    )
    let catalog = EvaluationsAPICatalog(
        source: source,
        symbols: [
            EvaluationsAPISymbol(
                name: "Evaluation",
                kind: .protocol,
                declaration: "public protocol Evaluation {}",
                availability: [],
                sourceLocation: EvaluationsAPISourceLocation(
                    path: source.interfacePath,
                    startLine: 1,
                    endLine: 1
                )
            )
        ]
    )
    let data = try JSONEncoder().encode(ApiListPayload(catalog: catalog))
    let json = try #require(
        try JSONSerialization.jsonObject(with: data) as? [String: Any]
    )

    #expect(json["schemaVersion"] as? String == "xceval.evaluations-api/v1")
    #expect(json["command"] as? String == "api list")
    #expect(json["count"] as? Int == 1)
}

@Test("Capabilities cover native, orchestrated, and producer-owned work")
func exposesCapabilityBoundaries() throws {
    let capabilities = CapabilitiesPayload(
        selectedXcode: nil
    ).capabilities

    #expect(capabilities.count == 20)
    #expect(capabilities.contains { $0.support == .native })
    #expect(capabilities.contains { $0.support == .orchestrated })
    #expect(capabilities.contains { $0.support == .producerOwned })

    let data = try JSONEncoder().encode(
        CapabilitiesPayload(selectedXcode: nil)
    )
    let json = try #require(
        try JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let encodedCapabilities = try #require(
        json["capabilities"] as? [[String: Any]]
    )
    #expect(encodedCapabilities.allSatisfy { $0["automationUse"] != nil })
    #expect(encodedCapabilities.allSatisfy { $0["agentUse"] == nil })
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

@Test("Artifact snapshots return only appended JSONL results")
func artifactSnapshotsFilterExistingJSONLines() throws {
    let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("xceval-snapshot-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: file) }
    let first = #"{"resultID":"FIRST","results":[]}"#
    let second = #"{"resultID":"SECOND","results":[]}"#

    try Data("\(first)\n".utf8).write(to: file)
    let before = artifactSnapshot(at: file)
    try Data("\(first)\n\(second)\n".utf8).write(to: file)
    let artifacts = try loadArtifacts(path: file.path)
    let changed = artifactsAddedOrChanged(
        artifacts,
        comparedTo: before[file.path]
    )

    #expect(changed.map(\.resultID) == ["SECOND"])
}

@Test("Artifact snapshots preserve appended duplicate JSONL results")
func artifactSnapshotsPreserveAppendedDuplicates() throws {
    let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("xceval-snapshot-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: file) }
    let artifact = #"{"resultID":"DUPLICATE","results":[]}"#

    try Data("\(artifact)\n".utf8).write(to: file)
    let before = artifactSnapshot(at: file)
    try Data("\(artifact)\n\(artifact)\n".utf8).write(to: file)
    let artifacts = try loadArtifacts(path: file.path)
    let changed = artifactsAddedOrChanged(
        artifacts,
        comparedTo: before[file.path]
    )

    #expect(changed.map(\.resultID) == ["DUPLICATE"])
}
