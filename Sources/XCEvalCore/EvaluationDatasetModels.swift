import Foundation
import XCEvalFormat

public enum EvaluationDatasetFormat: String, Codable, CaseIterable, Sendable {
    case json
    case jsonLines = "jsonl"
}

public struct EvaluationDatasetCodec: Codable, Equatable, Sendable {
    public let identifier: String
    public let version: String
    public let command: [String]

    public init(
        identifier: String,
        version: String,
        command: [String]
    ) {
        self.identifier = identifier
        self.version = version
        self.command = command
    }

    public func validate() throws {
        guard !identifier.trimmed.isEmpty else {
            throw EvaluationDatasetModelError.emptyCodecIdentifier
        }
        guard !version.trimmed.isEmpty else {
            throw EvaluationDatasetModelError.emptyCodecVersion
        }
        guard
            !command.isEmpty,
            command.allSatisfy({ !$0.trimmed.isEmpty })
        else {
            throw EvaluationDatasetModelError.emptyCodecCommand
        }
    }
}

public struct EvaluationDatasetCaseIdentity:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let caseID: String
    public let revision: Int
    public let contentDigest: ContentDigest

    public init(
        caseID: String,
        revision: Int,
        contentDigest: ContentDigest
    ) {
        self.caseID = caseID
        self.revision = revision
        self.contentDigest = contentDigest
    }

    public func validate() throws {
        guard !caseID.trimmed.isEmpty else {
            throw EvaluationDatasetModelError.emptyCaseID
        }
        guard revision > 0 else {
            throw EvaluationDatasetModelError.invalidCaseRevision(
                caseID: caseID,
                revision: revision
            )
        }
    }
}

public enum EvaluationDatasetCaseCategory:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case golden
    case edge
    case adversarial
    case knownFailure = "known-failure"
    case holdout
}

public enum EvaluationDatasetProvenanceKind:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case manual
    case productionCapture = "production-capture"
    case synthetic
    case imported
}

public struct EvaluationDatasetCaseProvenance:
    Codable,
    Equatable,
    Sendable
{
    public let kind: EvaluationDatasetProvenanceKind
    public let source: String?
    public let parentCaseIDs: [String]
    public let generationRunID: String?
    public let resultID: String?
    public let consentRecorded: Bool?
    public let redactions: [String]

    public init(
        kind: EvaluationDatasetProvenanceKind,
        source: String? = nil,
        parentCaseIDs: [String] = [],
        generationRunID: String? = nil,
        resultID: String? = nil,
        consentRecorded: Bool? = nil,
        redactions: [String] = []
    ) {
        self.kind = kind
        self.source = source
        self.parentCaseIDs = parentCaseIDs
        self.generationRunID = generationRunID
        self.resultID = resultID
        self.consentRecorded = consentRecorded
        self.redactions = redactions
    }

    public func validate() throws {
        if let source, source.trimmed.isEmpty {
            throw EvaluationDatasetModelError.emptyProvenanceSource
        }
        if let generationRunID, generationRunID.trimmed.isEmpty {
            throw EvaluationDatasetModelError.emptyGenerationRunID
        }
        if let resultID, resultID.trimmed.isEmpty {
            throw EvaluationDatasetModelError.emptyResultID
        }
        guard parentCaseIDs.allSatisfy({ !$0.trimmed.isEmpty }) else {
            throw EvaluationDatasetModelError.emptyParentCaseID
        }
        guard Set(parentCaseIDs).count == parentCaseIDs.count else {
            throw EvaluationDatasetModelError.duplicateParentCaseID
        }
        guard redactions.allSatisfy({ !$0.trimmed.isEmpty }) else {
            throw EvaluationDatasetModelError.emptyRedaction
        }
    }
}

public struct EvaluationDatasetCaseDescriptor:
    Codable,
    Equatable,
    Sendable
{
    public let identity: EvaluationDatasetCaseIdentity
    public let category: EvaluationDatasetCaseCategory
    public let provenance: EvaluationDatasetCaseProvenance

    public init(
        identity: EvaluationDatasetCaseIdentity,
        category: EvaluationDatasetCaseCategory,
        provenance: EvaluationDatasetCaseProvenance
    ) {
        self.identity = identity
        self.category = category
        self.provenance = provenance
    }

    public func validate() throws {
        try identity.validate()
        try provenance.validate()
    }
}

public struct EvaluationDatasetManifest:
    Codable,
    Equatable,
    Sendable
{
    public static let currentSchemaVersion = "xceval.dataset/v1"

    public let schemaVersion: String
    public let datasetID: String
    public let displayName: String?
    public let path: String
    public let format: EvaluationDatasetFormat
    public let sampleType: String
    public let codec: EvaluationDatasetCodec
    public let datasetDigest: ContentDigest
    public let cases: [EvaluationDatasetCaseDescriptor]

    public init(
        schemaVersion: String = Self.currentSchemaVersion,
        datasetID: String,
        displayName: String? = nil,
        path: String,
        format: EvaluationDatasetFormat,
        sampleType: String,
        codec: EvaluationDatasetCodec,
        datasetDigest: ContentDigest,
        cases: [EvaluationDatasetCaseDescriptor]
    ) {
        self.schemaVersion = schemaVersion
        self.datasetID = datasetID
        self.displayName = displayName
        self.path = path
        self.format = format
        self.sampleType = sampleType
        self.codec = codec
        self.datasetDigest = datasetDigest
        self.cases = cases
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw EvaluationDatasetModelError.unsupportedDatasetSchema(
                schemaVersion
            )
        }
        guard !datasetID.trimmed.isEmpty else {
            throw EvaluationDatasetModelError.emptyDatasetID
        }
        if let displayName, displayName.trimmed.isEmpty {
            throw EvaluationDatasetModelError.emptyDisplayName
        }
        guard !path.trimmed.isEmpty else {
            throw EvaluationDatasetModelError.emptyDatasetPath
        }
        guard !sampleType.trimmed.isEmpty else {
            throw EvaluationDatasetModelError.emptySampleType
        }
        try codec.validate()
        try validateUniqueCases(cases)
    }
}

public struct EvaluationDatasetSelectionManifest:
    Codable,
    Equatable,
    Sendable
{
    public static let currentSchemaVersion = "xceval.selection/v1"

    public let schemaVersion: String
    public let datasetID: String
    public let datasetDigest: ContentDigest
    public let cases: [EvaluationDatasetCaseIdentity]

    public init(
        schemaVersion: String = Self.currentSchemaVersion,
        datasetID: String,
        datasetDigest: ContentDigest,
        cases: [EvaluationDatasetCaseIdentity]
    ) {
        self.schemaVersion = schemaVersion
        self.datasetID = datasetID
        self.datasetDigest = datasetDigest
        self.cases = cases
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw EvaluationDatasetModelError.unsupportedSelectionSchema(
                schemaVersion
            )
        }
        guard !datasetID.trimmed.isEmpty else {
            throw EvaluationDatasetModelError.emptyDatasetID
        }
        try validateUniqueIdentities(cases)
    }

    public func validate(against manifest: EvaluationDatasetManifest) throws {
        try validate()
        try manifest.validate()
        guard datasetID == manifest.datasetID else {
            throw EvaluationDatasetModelError.selectionDatasetMismatch(
                expected: manifest.datasetID,
                actual: datasetID
            )
        }
        guard datasetDigest == manifest.datasetDigest else {
            throw EvaluationDatasetModelError.selectionDigestMismatch(
                expected: manifest.datasetDigest,
                actual: datasetDigest
            )
        }

        let available = Dictionary(
            uniqueKeysWithValues: manifest.cases.map {
                ($0.identity.caseID, $0.identity)
            }
        )
        for selected in cases {
            guard let current = available[selected.caseID] else {
                throw EvaluationDatasetModelError.selectionCaseMissing(
                    selected.caseID
                )
            }
            guard current == selected else {
                throw EvaluationDatasetModelError.selectionCaseChanged(
                    selected.caseID
                )
            }
        }
    }
}

public enum EvaluationDatasetGroundTruthState:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case preserved
    case notRequired = "not-required"
    case needsGroundTruth = "needs-ground-truth"
}

public struct EvaluationDatasetCaseDraft:
    Codable,
    Equatable,
    Sendable
{
    public let draftID: String
    public let proposedCaseID: String?
    public let category: EvaluationDatasetCaseCategory
    public let provenance: EvaluationDatasetCaseProvenance
    public let sample: JSONValue
    public let groundTruthState: EvaluationDatasetGroundTruthState

    public init(
        draftID: String,
        proposedCaseID: String? = nil,
        category: EvaluationDatasetCaseCategory,
        provenance: EvaluationDatasetCaseProvenance,
        sample: JSONValue,
        groundTruthState: EvaluationDatasetGroundTruthState
    ) {
        self.draftID = draftID
        self.proposedCaseID = proposedCaseID
        self.category = category
        self.provenance = provenance
        self.sample = sample
        self.groundTruthState = groundTruthState
    }

    public func validate() throws {
        guard !draftID.trimmed.isEmpty else {
            throw EvaluationDatasetModelError.emptyDraftID
        }
        if let proposedCaseID, proposedCaseID.trimmed.isEmpty {
            throw EvaluationDatasetModelError.emptyCaseID
        }
        try provenance.validate()
    }
}

public struct EvaluationDatasetQuarantinedCase:
    Codable,
    Equatable,
    Sendable
{
    public let draft: EvaluationDatasetCaseDraft
    public let reasons: [String]

    public init(
        draft: EvaluationDatasetCaseDraft,
        reasons: [String]
    ) {
        self.draft = draft
        self.reasons = reasons
    }

    public func validate() throws {
        try draft.validate()
        guard
            !reasons.isEmpty,
            reasons.allSatisfy({ !$0.trimmed.isEmpty })
        else {
            throw EvaluationDatasetModelError.emptyQuarantineReason
        }
    }
}

public struct EvaluationDatasetQuarantine:
    Codable,
    Equatable,
    Sendable
{
    public static let currentSchemaVersion = "xceval.quarantine/v1"

    public let schemaVersion: String
    public let runID: String
    public let datasetID: String
    public let sourceDatasetDigest: ContentDigest
    public let accepted: [EvaluationDatasetCaseDraft]
    public let rejected: [EvaluationDatasetQuarantinedCase]

    public init(
        schemaVersion: String = Self.currentSchemaVersion,
        runID: String,
        datasetID: String,
        sourceDatasetDigest: ContentDigest,
        accepted: [EvaluationDatasetCaseDraft],
        rejected: [EvaluationDatasetQuarantinedCase]
    ) {
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.datasetID = datasetID
        self.sourceDatasetDigest = sourceDatasetDigest
        self.accepted = accepted
        self.rejected = rejected
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw EvaluationDatasetModelError.unsupportedQuarantineSchema(
                schemaVersion
            )
        }
        guard !runID.trimmed.isEmpty else {
            throw EvaluationDatasetModelError.emptyRunID
        }
        guard !datasetID.trimmed.isEmpty else {
            throw EvaluationDatasetModelError.emptyDatasetID
        }
        for draft in accepted {
            try draft.validate()
        }
        for quarantined in rejected {
            try quarantined.validate()
        }
        let draftIDs = accepted.map(\.draftID) + rejected.map(\.draft.draftID)
        guard Set(draftIDs).count == draftIDs.count else {
            throw EvaluationDatasetModelError.duplicateDraftID
        }
    }
}

public struct EvaluationDatasetCaseRevisionChange:
    Codable,
    Equatable,
    Sendable
{
    public let before: EvaluationDatasetCaseIdentity
    public let after: EvaluationDatasetCaseIdentity

    public init(
        before: EvaluationDatasetCaseIdentity,
        after: EvaluationDatasetCaseIdentity
    ) {
        self.before = before
        self.after = after
    }

    public func validate() throws {
        try before.validate()
        try after.validate()
        guard before.caseID == after.caseID else {
            throw EvaluationDatasetModelError.revisionCaseIDMismatch(
                before: before.caseID,
                after: after.caseID
            )
        }
        guard after.revision > before.revision else {
            throw EvaluationDatasetModelError.revisionDidNotAdvance(
                caseID: before.caseID,
                before: before.revision,
                after: after.revision
            )
        }
        guard after.contentDigest != before.contentDigest else {
            throw EvaluationDatasetModelError.revisionContentUnchanged(
                before.caseID
            )
        }
    }
}

public struct EvaluationDatasetPromotionDiff:
    Codable,
    Equatable,
    Sendable
{
    public static let currentSchemaVersion = "xceval.promotion-diff/v1"

    public let schemaVersion: String
    public let datasetID: String
    public let baseDatasetDigest: ContentDigest
    public let resultingDatasetDigest: ContentDigest
    public let added: [EvaluationDatasetCaseIdentity]
    public let revised: [EvaluationDatasetCaseRevisionChange]
    public let removed: [EvaluationDatasetCaseIdentity]

    public init(
        schemaVersion: String = Self.currentSchemaVersion,
        datasetID: String,
        baseDatasetDigest: ContentDigest,
        resultingDatasetDigest: ContentDigest,
        added: [EvaluationDatasetCaseIdentity] = [],
        revised: [EvaluationDatasetCaseRevisionChange] = [],
        removed: [EvaluationDatasetCaseIdentity] = []
    ) {
        self.schemaVersion = schemaVersion
        self.datasetID = datasetID
        self.baseDatasetDigest = baseDatasetDigest
        self.resultingDatasetDigest = resultingDatasetDigest
        self.added = added
        self.revised = revised
        self.removed = removed
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw EvaluationDatasetModelError.unsupportedPromotionDiffSchema(
                schemaVersion
            )
        }
        guard !datasetID.trimmed.isEmpty else {
            throw EvaluationDatasetModelError.emptyDatasetID
        }
        guard baseDatasetDigest != resultingDatasetDigest else {
            throw EvaluationDatasetModelError.promotionDidNotChangeDataset
        }
        try validateUniqueIdentities(added + removed)
        for change in revised {
            try change.validate()
        }

        let changedIDs =
            added.map(\.caseID)
            + revised.map(\.before.caseID)
            + removed.map(\.caseID)
        guard Set(changedIDs).count == changedIDs.count else {
            throw EvaluationDatasetModelError.duplicatePromotionCaseID
        }
    }
}

public enum EvaluationDatasetModelError: LocalizedError, Equatable {
    case unsupportedDatasetSchema(String)
    case unsupportedSelectionSchema(String)
    case unsupportedQuarantineSchema(String)
    case unsupportedPromotionDiffSchema(String)
    case emptyDatasetID
    case emptyDisplayName
    case emptyDatasetPath
    case emptySampleType
    case emptyCodecIdentifier
    case emptyCodecVersion
    case emptyCodecCommand
    case emptyCaseID
    case invalidCaseRevision(caseID: String, revision: Int)
    case duplicateCaseID(String)
    case emptyProvenanceSource
    case emptyGenerationRunID
    case emptyResultID
    case emptyParentCaseID
    case duplicateParentCaseID
    case emptyRedaction
    case selectionDatasetMismatch(expected: String, actual: String)
    case selectionDigestMismatch(
        expected: ContentDigest,
        actual: ContentDigest
    )
    case selectionCaseMissing(String)
    case selectionCaseChanged(String)
    case emptyDraftID
    case duplicateDraftID
    case emptyQuarantineReason
    case emptyRunID
    case revisionCaseIDMismatch(before: String, after: String)
    case revisionDidNotAdvance(caseID: String, before: Int, after: Int)
    case revisionContentUnchanged(String)
    case promotionDidNotChangeDataset
    case duplicatePromotionCaseID

    public var errorDescription: String? {
        switch self {
        case .unsupportedDatasetSchema(let value):
            "Unsupported dataset schema '\(value)'."
        case .unsupportedSelectionSchema(let value):
            "Unsupported dataset selection schema '\(value)'."
        case .unsupportedQuarantineSchema(let value):
            "Unsupported dataset quarantine schema '\(value)'."
        case .unsupportedPromotionDiffSchema(let value):
            "Unsupported dataset promotion diff schema '\(value)'."
        case .emptyDatasetID:
            "Dataset IDs must not be empty."
        case .emptyDisplayName:
            "Dataset display names must not be empty when present."
        case .emptyDatasetPath:
            "Dataset paths must not be empty."
        case .emptySampleType:
            "Dataset sample types must not be empty."
        case .emptyCodecIdentifier:
            "Dataset codec identifiers must not be empty."
        case .emptyCodecVersion:
            "Dataset codec versions must not be empty."
        case .emptyCodecCommand:
            "Dataset codec commands must contain only nonempty arguments."
        case .emptyCaseID:
            "Dataset case IDs must not be empty."
        case .invalidCaseRevision(let caseID, let revision):
            "Dataset case '\(caseID)' has invalid revision \(revision)."
        case .duplicateCaseID(let caseID):
            "Dataset case ID '\(caseID)' is duplicated."
        case .emptyProvenanceSource:
            "Dataset provenance sources must not be empty when present."
        case .emptyGenerationRunID:
            "Dataset generation run IDs must not be empty when present."
        case .emptyResultID:
            "Dataset result IDs must not be empty when present."
        case .emptyParentCaseID:
            "Dataset parent case IDs must not be empty."
        case .duplicateParentCaseID:
            "Dataset parent case IDs must be unique."
        case .emptyRedaction:
            "Dataset redaction descriptions must not be empty."
        case .selectionDatasetMismatch(let expected, let actual):
            "Selection dataset '\(actual)' does not match '\(expected)'."
        case .selectionDigestMismatch(let expected, let actual):
            "Selection digest '\(actual)' does not match '\(expected)'."
        case .selectionCaseMissing(let caseID):
            "Selected dataset case '\(caseID)' is missing."
        case .selectionCaseChanged(let caseID):
            "Selected dataset case '\(caseID)' changed revision or content."
        case .emptyDraftID:
            "Dataset draft IDs must not be empty."
        case .duplicateDraftID:
            "Dataset draft IDs must be unique within quarantine."
        case .emptyQuarantineReason:
            "Rejected dataset drafts require nonempty quarantine reasons."
        case .emptyRunID:
            "Dataset quarantine run IDs must not be empty."
        case .revisionCaseIDMismatch(let before, let after):
            "Revision change case ID '\(after)' does not match '\(before)'."
        case .revisionDidNotAdvance(let caseID, let before, let after):
            "Dataset case '\(caseID)' revision did not advance from \(before) to \(after)."
        case .revisionContentUnchanged(let caseID):
            "Dataset case '\(caseID)' revision changed without content changing."
        case .promotionDidNotChangeDataset:
            "Promotion base and resulting dataset digests are identical."
        case .duplicatePromotionCaseID:
            "A dataset case appears in more than one promotion change."
        }
    }
}

private func validateUniqueCases(
    _ cases: [EvaluationDatasetCaseDescriptor]
) throws {
    for descriptor in cases {
        try descriptor.validate()
    }
    try validateUniqueIdentities(cases.map(\.identity))
}

private func validateUniqueIdentities(
    _ identities: [EvaluationDatasetCaseIdentity]
) throws {
    var caseIDs = Set<String>()
    for identity in identities {
        try identity.validate()
        guard caseIDs.insert(identity.caseID).inserted else {
            throw EvaluationDatasetModelError.duplicateCaseID(identity.caseID)
        }
    }
}

extension String {
    fileprivate var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
