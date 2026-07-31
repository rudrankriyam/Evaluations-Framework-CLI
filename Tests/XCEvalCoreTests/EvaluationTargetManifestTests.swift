import Foundation
import Testing

@testable import XCEvalCore

@Test("Target manifests validate stable identities and environment allowlists")
func targetManifestValidation() throws {
    let target = EvaluationTarget(
        id: "search-quality",
        workingDirectory: ".",
        argv: ["swift", "run", "SearchQualityEvaluate"],
        environment: EvaluationTargetEnvironment(
            inherit: ["DEVELOPER_DIR", "MODEL_API_KEY"],
            set: ["XCEVAL_MODE": "evaluation"]
        ),
        outputs: [
            EvaluationTargetOutput(
                role: "evaluation-results",
                path: ".xceval/results"
            )
        ],
        requirements: [
            EvaluationTargetRequirement(
                capability: "apple.evaluations",
                minimumVersion: "27"
            )
        ],
        sampleKeyPointer: "/record/id"
    )
    let manifest = EvaluationTargetManifest(targets: [target])

    try manifest.validate()
    #expect(try manifest.target(id: "search-quality") == target)
    #expect(target.revision.hasPrefix("sha256:"))
    #expect(target.revision.count == 71)

    let environment = target.resolvedEnvironment(
        from: [
            "DEVELOPER_DIR": "/Applications/Xcode-beta.app",
            "UNDECLARED_SECRET": "must-not-leak"
        ]
    )
    #expect(environment["DEVELOPER_DIR"] != nil)
    #expect(environment["MODEL_API_KEY"] == nil)
    #expect(environment["XCEVAL_MODE"] == "evaluation")
    #expect(environment["UNDECLARED_SECRET"] == nil)
}

@Test("Target manifests reject duplicate and unsafe declarations")
func targetManifestFailures() throws {
    let target = EvaluationTarget(
        id: "duplicate",
        argv: ["true"],
        outputs: [
            EvaluationTargetOutput(role: "results", path: "results")
        ]
    )
    #expect(throws: EvaluationTargetManifestError.duplicateTarget("duplicate")) {
        try EvaluationTargetManifest(targets: [target, target]).validate()
    }

    let invalid = EvaluationTarget(
        id: "../escape",
        argv: ["true"],
        outputs: [
            EvaluationTargetOutput(role: "results", path: "results")
        ]
    )
    #expect(throws: EvaluationTargetManifestError.invalidTargetID("../escape")) {
        try invalid.validate()
    }
}
