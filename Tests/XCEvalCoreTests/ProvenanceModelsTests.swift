import Foundation
import Testing

@testable import XCEvalCore

@Test("Content digests are validated and deterministic")
func validatesContentDigests() throws {
    let digest = ContentDigest(data: Data("abc".utf8))
    #expect(
        digest.rawValue
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    )
    #expect(ContentDigest(rawValue: digest.rawValue) == digest)
    #expect(ContentDigest(rawValue: digest.rawValue.uppercased()) == nil)
    #expect(ContentDigest(rawValue: "short") == nil)
    let encoded = try JSONEncoder().encode(digest)
    #expect(String(data: encoded, encoding: .utf8)?.contains("sha256:") == true)
    #expect(try JSONDecoder().decode(ContentDigest.self, from: encoded) == digest)

    let first = try ContentDigest.canonicalJSON(["b": 2, "a": 1])
    let second = try ContentDigest.canonicalJSON(["a": 1, "b": 2])
    #expect(first == second)
}

@Test("Environment descriptors redact secrets and unapproved values")
func redactsEnvironment() {
    let descriptor = RedactedEnvironmentDescriptor(
        environment: [
            "API_TOKEN": "never-print-me",
            "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
            "UNLISTED": "private-by-default"
        ],
        revealValuesFor: ["API_TOKEN", "DEVELOPER_DIR"]
    )

    #expect(
        descriptor.variables.map(\.name) == [
            "API_TOKEN",
            "DEVELOPER_DIR",
            "UNLISTED"
        ])
    let token = descriptor.variables[0]
    #expect(token.disclosure == .presenceOnly)
    #expect(token.value == nil)
    #expect(token.valueDigest == nil)

    let developerDirectory = descriptor.variables[1]
    #expect(developerDirectory.disclosure == .plainText)
    #expect(
        developerDirectory.value
            == "/Applications/Xcode.app/Contents/Developer"
    )
    #expect(developerDirectory.valueDigest == nil)

    let unlisted = descriptor.variables[2]
    #expect(unlisted.disclosure == .digest)
    #expect(unlisted.value == nil)
    #expect(unlisted.valueDigest != nil)
}

@Test("Provenance manifests preserve independent trust digests")
func roundTripsProvenanceManifest() throws {
    let subject = ContentDigest(data: Data("subject".utf8))
    let contract = ContentDigest(data: Data("contract".utf8))
    let execution = ContentDigest(data: Data("execution".utf8))
    let manifest = testProvenanceManifest(
        subject: subject,
        contract: contract,
        execution: execution
    )

    let data = try JSONEncoder().encode(manifest)
    let decoded = try JSONDecoder().decode(
        EvaluationProvenanceManifest.self,
        from: data
    )
    #expect(decoded == manifest)
    #expect(decoded.integrity.subject != decoded.integrity.evaluationContract)
    #expect(decoded.mutations.first?.classification == .subject)
    #expect(decoded.artifacts.first?.reference.byteCount == 6)
}

private func testProvenanceManifest(
    subject: ContentDigest,
    contract: ContentDigest,
    execution: ContentDigest
) -> EvaluationProvenanceManifest {
    EvaluationProvenanceManifest(
        runID: "run-2026-07-31",
        createdAt: Date(timeIntervalSince1970: 1_785_456_000),
        integrity: EvaluationIntegrityDigests(
            subject: subject,
            evaluationContract: contract,
            execution: execution
        ),
        git: GitProvenanceEvidence(
            baseCommit: "base",
            candidateCommit: "candidate",
            tree: "tree",
            patch: ContentDigest(data: Data("patch".utf8)),
            dirty: true
        ),
        toolchain: ToolchainProvenanceEvidence(
            xcevalVersion: "0.3.0",
            xcevalBinary: ContentDigest(data: Data("xceval".utf8)),
            swiftVersion: "6.2",
            xcodeVersion: "27.0"
        ),
        environment: RedactedEnvironmentDescriptor(
            environment: ["TOKEN": "secret"]
        ),
        mutations: [
            ProvenanceMutation(
                path: "Sources/Feature.swift",
                classification: .subject,
                after: subject
            )
        ],
        artifacts: [
            ProvenanceArtifact(
                role: .nativeResult,
                reference: ContentAddressedReference(
                    data: Data("result".utf8),
                    mediaType: "application/json",
                    logicalName: "result.xcevalresult"
                )
            )
        ]
    )
}
