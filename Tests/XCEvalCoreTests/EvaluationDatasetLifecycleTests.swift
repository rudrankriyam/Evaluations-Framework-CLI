import Foundation
import Testing
import XCEvalFormat

@testable import XCEvalCore

private struct TestSample: Codable, Equatable, Sendable {
    let input: String
    let expected: String?
}

private struct NarrowSample: Codable, Equatable, Sendable {
    let input: String
}

@Test("Dataset manifests preserve stable typed case metadata")
func datasetManifestRoundTrip() throws {
    let sample: JSONValue = .object([
        "expected": .string("PARIS"),
        "input": .string("Capital of France?")
    ])
    let caseDigest = try EvaluationDatasetDigest.canonicalJSONValue(sample)
    let datasetDigest = try EvaluationDatasetDigest.canonicalRecords([sample])
    let identity = EvaluationDatasetCaseIdentity(
        caseID: "capital-france",
        revision: 1,
        contentDigest: caseDigest
    )
    let descriptor = EvaluationDatasetCaseDescriptor(
        identity: identity,
        category: .golden,
        provenance: EvaluationDatasetCaseProvenance(kind: .manual)
    )
    let manifest = EvaluationDatasetManifest(
        datasetID: "geography",
        displayName: "Geography",
        path: "Fixtures/geography.jsonl",
        format: .jsonLines,
        sampleType: "GeographySample",
        codec: EvaluationDatasetCodec(
            identifier: "geography-codec",
            version: "1",
            command: ["swift", "run", "geography-codec"]
        ),
        datasetDigest: datasetDigest,
        cases: [descriptor]
    )

    try manifest.validate()
    let encoded = try JSONEncoder().encode(manifest)
    let decoded = try JSONDecoder().decode(
        EvaluationDatasetManifest.self,
        from: encoded
    )
    #expect(decoded == manifest)

    let selection = EvaluationDatasetSelectionManifest(
        datasetID: "geography",
        datasetDigest: datasetDigest,
        cases: [identity]
    )
    try selection.validate(against: manifest)
}

@Test("Selection manifests reject stale case revisions")
func selectionRejectsChangedCase() throws {
    let oldDigest = EvaluationDatasetDigest.sha256(Data("old".utf8))
    let newDigest = EvaluationDatasetDigest.sha256(Data("new".utf8))
    let datasetDigest = EvaluationDatasetDigest.sha256(Data("dataset".utf8))
    let descriptor = EvaluationDatasetCaseDescriptor(
        identity: EvaluationDatasetCaseIdentity(
            caseID: "case-1",
            revision: 2,
            contentDigest: newDigest
        ),
        category: .knownFailure,
        provenance: EvaluationDatasetCaseProvenance(kind: .manual)
    )
    let manifest = EvaluationDatasetManifest(
        datasetID: "suite",
        path: "suite.json",
        format: .json,
        sampleType: "TestSample",
        codec: EvaluationDatasetCodec(
            identifier: "codec",
            version: "1",
            command: ["/usr/bin/true"]
        ),
        datasetDigest: datasetDigest,
        cases: [descriptor]
    )
    let stale = EvaluationDatasetSelectionManifest(
        datasetID: "suite",
        datasetDigest: datasetDigest,
        cases: [
            EvaluationDatasetCaseIdentity(
                caseID: "case-1",
                revision: 1,
                contentDigest: oldDigest
            )
        ]
    )

    #expect(
        throws: EvaluationDatasetModelError.selectionCaseChanged("case-1")
    ) {
        try stale.validate(against: manifest)
    }
}

@Test("Dataset manifests reject duplicate stable case IDs")
func datasetManifestRejectsDuplicateCaseIDs() throws {
    let contentDigest = EvaluationDatasetDigest.sha256(Data("case".utf8))
    let datasetDigest = EvaluationDatasetDigest.sha256(Data("dataset".utf8))
    let first = EvaluationDatasetCaseDescriptor(
        identity: EvaluationDatasetCaseIdentity(
            caseID: "case-1",
            revision: 1,
            contentDigest: contentDigest
        ),
        category: .golden,
        provenance: EvaluationDatasetCaseProvenance(kind: .manual)
    )
    let duplicate = EvaluationDatasetCaseDescriptor(
        identity: EvaluationDatasetCaseIdentity(
            caseID: "case-1",
            revision: 2,
            contentDigest: EvaluationDatasetDigest.sha256(Data("changed".utf8))
        ),
        category: .edge,
        provenance: EvaluationDatasetCaseProvenance(kind: .manual)
    )
    let manifest = EvaluationDatasetManifest(
        datasetID: "suite",
        path: "suite.jsonl",
        format: .jsonLines,
        sampleType: "TestSample",
        codec: EvaluationDatasetCodec(
            identifier: "codec",
            version: "1",
            command: ["/usr/bin/true"]
        ),
        datasetDigest: datasetDigest,
        cases: [first, duplicate]
    )

    #expect(
        throws: EvaluationDatasetModelError.duplicateCaseID("case-1")
    ) {
        try manifest.validate()
    }
}

@Test("Canonical JSON digests ignore object key order and whitespace")
func canonicalDatasetDigests() throws {
    let first = try JSONValue.decode(
        Data(#"{"input":"alpha","expected":"ALPHA"}"#.utf8)
    )
    let reordered = try JSONValue.decode(
        Data(
            """
            {
              "expected": "ALPHA",
              "input": "alpha"
            }
            """.utf8
        )
    )

    #expect(
        try EvaluationDatasetDigest.canonicalJSONValue(first)
            == EvaluationDatasetDigest.canonicalJSONValue(reordered)
    )
    #expect(
        try EvaluationDatasetDigest.canonicalJSONValue(first)
            == ContentDigest(data: try first.encodedData())
    )
}

@Test("Strict JSON validation reconciles every physical record")
func validatesJSONArrayWithoutSkipping() throws {
    let report = try EvaluationDatasetValidator.validate(
        Data(
            #"""
            [
              {"input":"alpha","expected":"ALPHA"},
              {"input":"beta","expected":"BETA"}
            ]
            """#.utf8
        ),
        as: TestSample.self
    )

    try report.requireValid()
    #expect(report.format == .json)
    #expect(report.counts.physical == 2)
    #expect(report.counts.decoded == 2)
    #expect(report.counts.accepted == 2)
    #expect(report.counts.skipped == 0)
    #expect(report.canonicalDigest != nil)
}

@Test("Strict JSONL validation exposes malformed rows")
func validatesJSONLinesWithoutSilentSkipping() throws {
    let report = try EvaluationDatasetValidator.validate(
        Data(
            """
            {"input":"alpha","expected":"ALPHA"}
            {"input":
            {"input":"beta","expected":"BETA"}
            """.utf8
        ),
        as: TestSample.self
    )

    #expect(!report.isValid)
    #expect(report.format == .jsonLines)
    #expect(report.counts.physical == 3)
    #expect(report.counts.decoded == 2)
    #expect(report.counts.accepted == 2)
    #expect(report.counts.skipped == 1)
    #expect(report.canonicalDigest == nil)
    #expect(report.issues.count == 1)
    #expect(report.issues[0].code == .malformedJSON)
    #expect(report.issues[0].sourceLine == 2)
    #expect(throws: EvaluationDatasetValidationError.self) {
        try report.requireValid()
    }
}

@Test("Strict validation rejects typed decoding that would erase fields")
func rejectsSemanticRoundTripLoss() throws {
    let report = try EvaluationDatasetValidator.validate(
        Data(#"[{"input":"alpha","unexpected":"must survive"}]"#.utf8),
        as: NarrowSample.self
    )

    #expect(report.counts.physical == 1)
    #expect(report.counts.decoded == 1)
    #expect(report.counts.accepted == 0)
    #expect(report.issues.map(\.code) == [.semanticRoundTripMismatch])
}

@Test("Validation leaves absent expected values absent")
func doesNotInventExpectedValues() throws {
    let report = try EvaluationDatasetValidator.validate(
        Data(#"[{"input":"prompt only"}]"#.utf8),
        as: TestSample.self
    )

    try report.requireValid()
    #expect(report.records.count == 1)
    #expect(report.records[0].sample.expected == nil)
    #expect(report.records[0].original["expected"] == nil)
}

@Test("Quarantine keeps accepted and rejected drafts separate")
func validatesQuarantineAndPromotionDiff() throws {
    let sourceDigest = EvaluationDatasetDigest.sha256(Data("source".utf8))
    let accepted = EvaluationDatasetCaseDraft(
        draftID: "draft-accepted",
        category: .edge,
        provenance: EvaluationDatasetCaseProvenance(
            kind: .synthetic,
            parentCaseIDs: ["seed-1"],
            generationRunID: "run-1"
        ),
        sample: .object(["input": .string("ambiguous input")]),
        groundTruthState: .needsGroundTruth
    )
    let rejected = EvaluationDatasetCaseDraft(
        draftID: "draft-rejected",
        category: .edge,
        provenance: EvaluationDatasetCaseProvenance(
            kind: .synthetic,
            generationRunID: "run-1"
        ),
        sample: .object(["input": .string("")]),
        groundTruthState: .needsGroundTruth
    )
    let quarantine = EvaluationDatasetQuarantine(
        runID: "run-1",
        datasetID: "suite",
        sourceDatasetDigest: sourceDigest,
        accepted: [accepted],
        rejected: [
            EvaluationDatasetQuarantinedCase(
                draft: rejected,
                reasons: ["Input was empty."]
            )
        ]
    )
    try quarantine.validate()

    let old = EvaluationDatasetCaseIdentity(
        caseID: "known-failure-1",
        revision: 1,
        contentDigest: EvaluationDatasetDigest.sha256(Data("old".utf8))
    )
    let new = EvaluationDatasetCaseIdentity(
        caseID: "known-failure-1",
        revision: 2,
        contentDigest: EvaluationDatasetDigest.sha256(Data("new".utf8))
    )
    let diff = EvaluationDatasetPromotionDiff(
        datasetID: "suite",
        baseDatasetDigest: sourceDigest,
        resultingDatasetDigest:
            EvaluationDatasetDigest.sha256(Data("result".utf8)),
        revised: [
            EvaluationDatasetCaseRevisionChange(before: old, after: new)
        ]
    )
    try diff.validate()
}

@Test("Promotion rejects changes to immutable expected values")
func promotionRejectsExpectedValueChanges() throws {
    let base: [JSONValue] = [
        .object([
            "expected": .string("ALPHA"),
            "id": .string("case-alpha"),
            "input": .string("alpha")
        ])
    ]
    let relabeled: [JSONValue] = [
        .object([
            "expected": .string("BETA"),
            "id": .string("case-alpha"),
            "input": .string("alpha"),
            "revision": .integer(2)
        ])
    ]

    #expect(
        throws:
            EvaluationDatasetLifecycleError.expectedValueChanged("case-alpha")
    ) {
        try EvaluationDatasetLifecycle.merge(
            base: base,
            drafts: relabeled,
            sampleKey: "/id"
        )
    }
}

@Test("Promotion fails when its optimistic base digest is stale")
func promotionRejectsStaleBaseDigest() throws {
    let base: [JSONValue] = [
        .object([
            "expected": .string("ALPHA"),
            "id": .string("case-alpha"),
            "input": .string("alpha")
        ])
    ]
    let stale = ContentDigest(data: Data("stale".utf8))

    #expect(
        throws: EvaluationDatasetLifecycleError.baseDatasetChanged(
            expected: stale,
            actual: try EvaluationDatasetDigest.canonicalRecords(base)
        )
    ) {
        try EvaluationDatasetLifecycle.merge(
            base: base,
            drafts: [],
            sampleKey: "/id",
            expectedBaseDatasetDigest: stale
        )
    }
}

@Test("Promotion distinguishes idempotent duplicates from revision conflicts")
func promotionHandlesDuplicateAndConflict() throws {
    let canonical: JSONValue = .object([
        "expected": .string("ALPHA"),
        "id": .string("case-alpha"),
        "input": .string("alpha")
    ])
    let duplicate = try EvaluationDatasetLifecycle.merge(
        base: [canonical],
        drafts: [canonical],
        sampleKey: "/id"
    )

    #expect(duplicate.records == [canonical])
    #expect(duplicate.added.isEmpty)
    #expect(duplicate.duplicates.map(\.caseID) == ["case-alpha"])

    let changedInput: JSONValue = .object([
        "expected": .string("ALPHA"),
        "id": .string("case-alpha"),
        "input": .string("changed"),
        "revision": .integer(2)
    ])
    #expect(
        throws: EvaluationDatasetLifecycleError.revisionConflict(
            caseID: "case-alpha",
            currentRevision: 1,
            proposedRevision: 2
        )
    ) {
        try EvaluationDatasetLifecycle.merge(
            base: [canonical],
            drafts: [changedInput],
            sampleKey: "/id"
        )
    }
}

@Test("Stable selection binds dataset, revision, content, and order")
func stableSelectionUsesExactCaseIdentities() throws {
    let alpha: JSONValue = .object([
        "expected": .string("ALPHA"),
        "id": .string("case-alpha"),
        "input": .string("alpha")
    ])
    let beta: JSONValue = .object([
        "expected": .string("BETA"),
        "id": .string("case-beta"),
        "input": .string("beta"),
        "revision": .integer(3)
    ])
    let records = [alpha, beta]
    let indexed = try EvaluationDatasetLifecycle.index(
        records,
        sampleKey: "/id"
    )
    let digest = try EvaluationDatasetDigest.canonicalRecords(records)
    let selection = EvaluationDatasetSelectionManifest(
        datasetID: "suite",
        datasetDigest: digest,
        cases: [indexed[1].identity, indexed[0].identity]
    )

    #expect(
        try EvaluationDatasetLifecycle.select(
            records,
            sampleKey: "/id",
            datasetID: "suite",
            selection: selection
        ) == [beta, alpha]
    )

    let stale = EvaluationDatasetSelectionManifest(
        datasetID: "suite",
        datasetDigest: digest,
        cases: [
            EvaluationDatasetCaseIdentity(
                caseID: "case-beta",
                revision: 2,
                contentDigest: indexed[1].identity.contentDigest
            )
        ]
    )
    #expect(
        throws:
            EvaluationDatasetModelError.selectionCaseChanged("case-beta")
    ) {
        try EvaluationDatasetLifecycle.select(
            records,
            sampleKey: "/id",
            datasetID: "suite",
            selection: stale
        )
    }
}

@Test("Quarantine deterministically retains every rejected candidate")
func quarantineRetainsRejectedCandidatesDeterministically() throws {
    let provenance = EvaluationDatasetCaseProvenance(
        kind: .synthetic,
        generationRunID: "run-1"
    )
    let accepted = EvaluationDatasetCaseDraft(
        draftID: "draft-b",
        proposedCaseID: "case-b",
        category: .edge,
        provenance: provenance,
        sample: .object(["input": .string("b")]),
        groundTruthState: .needsGroundTruth
    )
    let rejected = EvaluationDatasetCaseDraft(
        draftID: "draft-a",
        category: .adversarial,
        provenance: provenance,
        sample: .object(["input": .string("")]),
        groundTruthState: .needsGroundTruth
    )
    let sourceDigest = ContentDigest(data: Data("source".utf8))
    let quarantine = try EvaluationDatasetLifecycle.quarantine(
        runID: "run-1",
        datasetID: "suite",
        sourceDatasetDigest: sourceDigest,
        candidates: [
            EvaluationDatasetDraftCandidate(draft: accepted),
            EvaluationDatasetDraftCandidate(
                draft: rejected,
                rejectionReasons: ["empty input", "empty input", "no key"]
            )
        ]
    )

    #expect(quarantine.accepted.map(\.draftID) == ["draft-b"])
    #expect(quarantine.rejected.map(\.draft.draftID) == ["draft-a"])
    #expect(quarantine.rejected[0].reasons == ["empty input", "no key"])
    #expect(
        try EvaluationDatasetDigest.canonicalJSON(quarantine)
            == EvaluationDatasetDigest.canonicalJSON(quarantine)
    )
}
