import Foundation
import Testing

@testable import XCEvalCore

@Test("Destructive targets must be narrow descendants")
func validatesNarrowDestructiveTargets() throws {
    let root = URL(fileURLWithPath: "/tmp/xceval-tests/runs")
    let policy = DestructivePathPolicy(
        allowedRoot: root,
        protectedPaths: [
            root.appendingPathComponent("baseline/result.xcevalresult")
        ],
        homeDirectory: URL(fileURLWithPath: "/Users/tester")
    )

    try policy.validate(targets: [
        root.appendingPathComponent("candidate-1")
    ])

    #expect(throws: DestructivePathError.self) {
        try policy.validate(targets: [root])
    }
    #expect(throws: DestructivePathError.self) {
        try policy.validate(targets: [
            URL(fileURLWithPath: "/tmp/xceval-tests")
        ])
    }
    #expect(throws: DestructivePathError.self) {
        try policy.validate(targets: [
            root.appendingPathComponent("baseline")
        ])
    }
}

@Test("Destructive targets cannot overlap one another")
func rejectsOverlappingDestructiveTargets() {
    let root = URL(fileURLWithPath: "/tmp/xceval-tests/runs")
    let candidate = root.appendingPathComponent("candidate")
    let policy = DestructivePathPolicy(
        allowedRoot: root,
        homeDirectory: URL(fileURLWithPath: "/Users/tester")
    )

    #expect(throws: DestructivePathError.self) {
        try policy.validate(targets: [
            candidate,
            candidate.appendingPathComponent("logs")
        ])
    }
}

@Test("Nonexistent targets canonicalize through an existing symlink ancestor")
func canonicalizesNonexistentTargetsThroughSymlinks() throws {
    let fileManager = FileManager.default
    let testRoot = fileManager.temporaryDirectory
        .appendingPathComponent("xceval-symlink-tests-\(UUID().uuidString)")
    let realRoot = testRoot.appendingPathComponent("real", isDirectory: true)
    let aliasRoot = testRoot.appendingPathComponent("alias", isDirectory: true)
    try fileManager.createDirectory(
        at: realRoot,
        withIntermediateDirectories: true
    )
    try fileManager.createSymbolicLink(
        at: aliasRoot,
        withDestinationURL: realRoot
    )
    defer { try? fileManager.removeItem(at: testRoot) }

    let policy = DestructivePathPolicy(
        allowedRoot: aliasRoot,
        homeDirectory: URL(fileURLWithPath: "/Users/tester")
    )
    try policy.validate(targets: [
        aliasRoot.appendingPathComponent("new-output.json")
    ])
}

@Test("Run planning is unique and refuses replacement")
func plansImmutableRunDirectory() throws {
    let fileManager = FileManager.default
    let testRoot = fileManager.temporaryDirectory
        .appendingPathComponent("xceval-path-tests-\(UUID().uuidString)")
    try fileManager.createDirectory(
        at: testRoot,
        withIntermediateDirectories: true
    )
    defer { try? fileManager.removeItem(at: testRoot) }

    let plan = try EvaluationRunDirectoryPlan.plan(
        runID: "attempt-001",
        runsRoot: testRoot,
        fileManager: fileManager
    )
    #expect(plan.runDirectory.lastPathComponent == "attempt-001")
    #expect(plan.artifactsDirectory.lastPathComponent == "artifacts")
    #expect(plan.logsDirectory.lastPathComponent == "logs")
    #expect(plan.provenanceFile.lastPathComponent == "provenance.json")

    try fileManager.createDirectory(
        at: plan.runDirectory,
        withIntermediateDirectories: true
    )
    #expect(throws: EvaluationRunDirectoryError.self) {
        try EvaluationRunDirectoryPlan.plan(
            runID: "attempt-001",
            runsRoot: testRoot,
            fileManager: fileManager
        )
    }
    #expect(throws: EvaluationRunDirectoryError.self) {
        try EvaluationRunDirectoryPlan.plan(
            runID: "../escape",
            runsRoot: testRoot,
            fileManager: fileManager
        )
    }
}

@Test("Run planning rejects broad roots")
func rejectsBroadRunRoots() {
    #expect(throws: DestructivePathError.self) {
        try EvaluationRunDirectoryPlan.plan(
            runID: "attempt",
            runsRoot: URL(fileURLWithPath: "/")
        )
    }
}
