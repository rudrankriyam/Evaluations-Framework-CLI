import Foundation
import Testing
import XCEvalCore

@testable import XCEvalCLI

@Test("Plan parses run identity and provenance disclosure options")
func parsesPlanOptions() throws {
    let command = try XCEvalRootCommand.parseAsRoot([
        "plan",
        "--run-id",
        "candidate-42",
        "--runs-root",
        "/tmp/xceval-runs",
        "--protect",
        "/tmp/repository",
        "--reveal-environment",
        "CI"
    ])
    let plan = try #require(command as? PlanCommand)

    #expect(plan.runID == "candidate-42")
    #expect(plan.runsRoot == "/tmp/xceval-runs")
    #expect(plan.protect == ["/tmp/repository"])
    #expect(plan.revealEnvironment == ["CI"])
}

@Test("Plan is read-only and redacts sensitive environment values")
func planDoesNotCreateItsRunDirectory() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
        "xceval-plan-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? fileManager.removeItem(at: root) }

    let parsed = try XCEvalRootCommand.parseAsRoot([
        "plan",
        "--run-id",
        "candidate-42",
        "--runs-root",
        root.path
    ])
    let command = try #require(parsed as? PlanCommand)
    let payload = try command.makePayload(
        environment: [
            "API_TOKEN": "do-not-leak",
            "CI": "true"
        ],
        now: Date(timeIntervalSince1970: 1_700_000_000),
        fileManager: fileManager
    )

    #expect(payload.readOnly)
    #expect(!payload.reserved)
    #expect(payload.run.runID == "candidate-42")
    #expect(payload.provenance.integrity == nil)
    #expect(payload.provenance.git == nil)
    #expect(payload.provenance.toolchain == nil)
    #expect(payload.provenance.requiredEvidence.contains("integrity.subject"))
    #expect(!fileManager.fileExists(atPath: root.path))

    let encoded = try JSONEncoder().encode(payload)
    let json = try #require(String(data: encoded, encoding: .utf8))
    #expect(!json.contains("do-not-leak"))
    #expect(!json.contains(#""API_TOKEN":"do-not-leak""#))
    #expect(json.contains(#""disclosure":"presence-only""#))
}

@Test("Replacement validation rejects protected and overlapping paths")
func forcedReplacementRejectsUnsafeTopology() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
        "xceval-replacement-\(UUID().uuidString)",
        isDirectory: true
    )
    let output = root.appendingPathComponent("output", isDirectory: true)
    let nested = output.appendingPathComponent("nested", isDirectory: true)
    let protected = output.appendingPathComponent(
        "repository",
        isDirectory: true
    )
    let home = root.appendingPathComponent("home", isDirectory: true)

    #expect(throws: DestructivePathError.self) {
        try validateForcedReplacement(
            targets: [output],
            protecting: [protected],
            homeDirectory: home
        )
    }
    #expect(throws: DestructivePathError.self) {
        try validateForcedReplacement(
            targets: [output, nested],
            homeDirectory: home
        )
    }
    #expect(throws: DestructivePathError.self) {
        try validateForcedReplacement(
            targets: [home],
            homeDirectory: home
        )
    }
}

@Test("Replacement validation permits unrelated sibling outputs")
func forcedReplacementAllowsSiblingOutputs() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "xceval-replacement-\(UUID().uuidString)",
        isDirectory: true
    )
    let home = root.appendingPathComponent("home", isDirectory: true)

    try validateForcedReplacement(
        targets: [
            root.appendingPathComponent("result.xcresult"),
            root.appendingPathComponent("result.evaluations")
        ],
        protecting: [root.appendingPathComponent("repository")],
        homeDirectory: home
    )
}

@Test("Atomic outputs may use the home directory as a narrow boundary")
func atomicOutputAllowsHomeDirectoryBoundary() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(
        "xceval-home-\(UUID().uuidString)",
        isDirectory: true
    )

    try validateForcedReplacement(
        targets: [home.appendingPathComponent("selection.json")],
        homeDirectory: home,
        allowsHomeDirectoryAsRoot: true
    )
}
