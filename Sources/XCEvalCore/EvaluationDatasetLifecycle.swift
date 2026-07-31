import Foundation
import XCEvalFormat

/// A dataset record bound to a stable logical identity and exact content.
public struct EvaluationDatasetIndexedRecord: Equatable, Sendable {
    public let identity: EvaluationDatasetCaseIdentity
    public let record: JSONValue

    public init(
        identity: EvaluationDatasetCaseIdentity,
        record: JSONValue
    ) {
        self.identity = identity
        self.record = record
    }
}

/// The deterministic result of merging reviewed drafts into a dataset snapshot.
public struct EvaluationDatasetMergeResult: Equatable, Sendable {
    public let baseDatasetDigest: ContentDigest
    public let resultingDatasetDigest: ContentDigest
    public let records: [JSONValue]
    public let added: [EvaluationDatasetCaseIdentity]
    public let duplicates: [EvaluationDatasetCaseIdentity]

    public init(
        baseDatasetDigest: ContentDigest,
        resultingDatasetDigest: ContentDigest,
        records: [JSONValue],
        added: [EvaluationDatasetCaseIdentity],
        duplicates: [EvaluationDatasetCaseIdentity]
    ) {
        self.baseDatasetDigest = baseDatasetDigest
        self.resultingDatasetDigest = resultingDatasetDigest
        self.records = records
        self.added = added
        self.duplicates = duplicates
    }
}

/// One generated candidate and the validation reasons that rejected it.
public struct EvaluationDatasetDraftCandidate: Equatable, Sendable {
    public let draft: EvaluationDatasetCaseDraft
    public let rejectionReasons: [String]

    public init(
        draft: EvaluationDatasetCaseDraft,
        rejectionReasons: [String] = []
    ) {
        self.draft = draft
        self.rejectionReasons = rejectionReasons
    }
}

/// Fail-closed, deterministic operations for versioned dataset lifecycles.
public enum EvaluationDatasetLifecycle {
    public static func index(
        _ records: [JSONValue],
        sampleKey: String
    ) throws -> [EvaluationDatasetIndexedRecord] {
        var seen = Set<String>()
        return try records.enumerated().map { index, record in
            guard let key = record.value(atJSONPointer: sampleKey) else {
                throw EvaluationDatasetLifecycleError.missingCaseID(
                    recordIndex: index,
                    pointer: sampleKey
                )
            }
            let caseID = displayCaseID(key)
            guard seen.insert(caseID).inserted else {
                throw EvaluationDatasetLifecycleError.duplicateCaseID(caseID)
            }
            let revision = try recordRevision(record, caseID: caseID)
            return EvaluationDatasetIndexedRecord(
                identity: EvaluationDatasetCaseIdentity(
                    caseID: caseID,
                    revision: revision,
                    contentDigest:
                        try EvaluationDatasetDigest.canonicalJSONValue(record)
                ),
                record: record
            )
        }
    }

    /// Selects exact identities, in manifest order, from an immutable snapshot.
    public static func select(
        _ records: [JSONValue],
        sampleKey: String,
        datasetID: String,
        selection: EvaluationDatasetSelectionManifest
    ) throws -> [JSONValue] {
        let digest = try EvaluationDatasetDigest.canonicalRecords(records)
        guard selection.datasetID == datasetID else {
            throw EvaluationDatasetModelError.selectionDatasetMismatch(
                expected: datasetID,
                actual: selection.datasetID
            )
        }
        guard selection.datasetDigest == digest else {
            throw EvaluationDatasetModelError.selectionDigestMismatch(
                expected: digest,
                actual: selection.datasetDigest
            )
        }
        try selection.validate()

        let indexed = try index(records, sampleKey: sampleKey)
        let available = Dictionary(
            uniqueKeysWithValues: indexed.map {
                ($0.identity.caseID, $0)
            }
        )
        return try selection.cases.map { requested in
            guard let current = available[requested.caseID] else {
                throw EvaluationDatasetModelError.selectionCaseMissing(
                    requested.caseID
                )
            }
            guard current.identity == requested else {
                throw EvaluationDatasetModelError.selectionCaseChanged(
                    requested.caseID
                )
            }
            return current.record
        }
    }

    /// Adds new reviewed records without silently revising canonical cases.
    ///
    /// A caller-provided base digest provides optimistic concurrency. Existing
    /// records are accepted only as exact idempotent duplicates; any content
    /// change must use an explicit, separately reviewed revision workflow.
    public static func merge(
        base: [JSONValue],
        drafts: [JSONValue],
        sampleKey: String,
        expectedBaseDatasetDigest: ContentDigest? = nil
    ) throws -> EvaluationDatasetMergeResult {
        let baseDigest = try EvaluationDatasetDigest.canonicalRecords(base)
        if let expectedBaseDatasetDigest,
            expectedBaseDatasetDigest != baseDigest
        {
            throw EvaluationDatasetLifecycleError.baseDatasetChanged(
                expected: expectedBaseDatasetDigest,
                actual: baseDigest
            )
        }

        let indexedBase = try index(base, sampleKey: sampleKey)
        let indexedDrafts = try index(drafts, sampleKey: sampleKey)
        let existing = Dictionary(
            uniqueKeysWithValues: indexedBase.map {
                ($0.identity.caseID, $0)
            }
        )
        var records = base
        var added: [EvaluationDatasetCaseIdentity] = []
        var duplicates: [EvaluationDatasetCaseIdentity] = []

        for draft in indexedDrafts {
            guard let canonical = existing[draft.identity.caseID] else {
                records.append(draft.record)
                added.append(draft.identity)
                continue
            }
            if canonical.identity.contentDigest
                == draft.identity.contentDigest
            {
                duplicates.append(canonical.identity)
                continue
            }
            if canonical.record["expected"] != draft.record["expected"] {
                throw EvaluationDatasetLifecycleError.expectedValueChanged(
                    draft.identity.caseID
                )
            }
            throw EvaluationDatasetLifecycleError.revisionConflict(
                caseID: draft.identity.caseID,
                currentRevision: canonical.identity.revision,
                proposedRevision: draft.identity.revision
            )
        }

        return EvaluationDatasetMergeResult(
            baseDatasetDigest: baseDigest,
            resultingDatasetDigest:
                try EvaluationDatasetDigest.canonicalRecords(records),
            records: records,
            added: added,
            duplicates: duplicates
        )
    }

    /// Reconciles every generated candidate into accepted or rejected output.
    public static func quarantine(
        runID: String,
        datasetID: String,
        sourceDatasetDigest: ContentDigest,
        candidates: [EvaluationDatasetDraftCandidate]
    ) throws -> EvaluationDatasetQuarantine {
        let sorted = candidates.sorted {
            $0.draft.draftID < $1.draft.draftID
        }
        let quarantine = EvaluationDatasetQuarantine(
            runID: runID,
            datasetID: datasetID,
            sourceDatasetDigest: sourceDatasetDigest,
            accepted: sorted.compactMap {
                $0.rejectionReasons.isEmpty ? $0.draft : nil
            },
            rejected: sorted.compactMap { candidate in
                guard !candidate.rejectionReasons.isEmpty else { return nil }
                return EvaluationDatasetQuarantinedCase(
                    draft: candidate.draft,
                    reasons: Array(Set(candidate.rejectionReasons)).sorted()
                )
            }
        )
        try quarantine.validate()
        return quarantine
    }
}

public enum EvaluationDatasetLifecycleError: LocalizedError, Equatable {
    case missingCaseID(recordIndex: Int, pointer: String)
    case duplicateCaseID(String)
    case invalidRevision(caseID: String, revision: Int)
    case baseDatasetChanged(expected: ContentDigest, actual: ContentDigest)
    case expectedValueChanged(String)
    case revisionConflict(
        caseID: String,
        currentRevision: Int,
        proposedRevision: Int
    )

    public var errorDescription: String? {
        switch self {
        case .missingCaseID(let index, let pointer):
            "Dataset record \(index) does not contain case ID \(pointer)."
        case .duplicateCaseID(let caseID):
            "Dataset case ID '\(caseID)' is duplicated."
        case .invalidRevision(let caseID, let revision):
            "Dataset case '\(caseID)' has invalid revision \(revision)."
        case .baseDatasetChanged(let expected, let actual):
            "Canonical dataset changed from '\(expected)' to '\(actual)'."
        case .expectedValueChanged(let caseID):
            "Draft case '\(caseID)' changes an immutable expected value."
        case .revisionConflict(
            let caseID,
            let currentRevision,
            let proposedRevision
        ):
            "Draft case '\(caseID)' conflicts with canonical revision "
                + "\(currentRevision) (proposed \(proposedRevision))."
        }
    }
}

private func displayCaseID(_ value: JSONValue) -> String {
    value.stringValue ?? value.canonicalJSONString
}

private func recordRevision(
    _ record: JSONValue,
    caseID: String
) throws -> Int {
    guard let value = record["revision"] else { return 1 }
    guard case .integer(let revision) = value,
        revision > 0,
        revision <= Int64(Int.max)
    else {
        let invalid = Int(value.doubleValue ?? 0)
        throw EvaluationDatasetLifecycleError.invalidRevision(
            caseID: caseID,
            revision: invalid
        )
    }
    return Int(revision)
}
