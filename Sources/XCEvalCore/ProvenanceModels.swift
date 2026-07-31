import CryptoKit
import Foundation

/// A lowercase SHA-256 digest used to bind provenance to exact bytes.
public struct ContentDigest:
    Codable,
    CustomStringConvertible,
    Equatable,
    Hashable,
    RawRepresentable,
    Sendable
{
    public static let algorithm = "sha256"

    public let rawValue: String

    public var description: String {
        "\(Self.algorithm):\(rawValue)"
    }

    public init?(rawValue: String) {
        guard
            rawValue.count == 64,
            rawValue.unicodeScalars.allSatisfy({
                CharacterSet(charactersIn: "0123456789abcdef").contains($0)
            })
        else {
            return nil
        }
        self.rawValue = rawValue
    }

    public init(data: Data) {
        rawValue = SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    public init(contentsOf url: URL) throws {
        self.init(data: try Data(contentsOf: url))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let encoded = try container.decode(String.self)
        let prefix = "\(Self.algorithm):"
        let rawValue =
            encoded.hasPrefix(prefix)
            ? String(encoded.dropFirst(prefix.count))
            : encoded
        guard let digest = ContentDigest(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a lowercase SHA-256 digest."
            )
        }
        self = digest
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    public static func canonicalJSON<Value: Encodable>(
        _ value: Value
    ) throws -> ContentDigest {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try ContentDigest(data: encoder.encode(value))
    }
}

/// A portable reference to immutable content.
public struct ContentAddressedReference:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let digest: ContentDigest
    public let byteCount: UInt64
    public let mediaType: String?
    public let logicalName: String?

    public init(
        digest: ContentDigest,
        byteCount: UInt64,
        mediaType: String? = nil,
        logicalName: String? = nil
    ) {
        self.digest = digest
        self.byteCount = byteCount
        self.mediaType = mediaType
        self.logicalName = logicalName
    }

    public init(
        data: Data,
        mediaType: String? = nil,
        logicalName: String? = nil
    ) {
        self.init(
            digest: ContentDigest(data: data),
            byteCount: UInt64(data.count),
            mediaType: mediaType,
            logicalName: logicalName
        )
    }
}

/// Separates intended product changes from changes to the system judging them.
public enum MutationClassification: String, Codable, CaseIterable, Sendable {
    case observation
    case ephemeral
    case subject
    case evaluationContract = "evaluation-contract"
    case executionHarness = "execution-harness"
    case externalEffect = "external-effect"
    case promotion
}

public struct ProvenanceMutation:
    Codable,
    Equatable,
    Sendable
{
    public let path: String
    public let classification: MutationClassification
    public let before: ContentDigest?
    public let after: ContentDigest?

    public init(
        path: String,
        classification: MutationClassification,
        before: ContentDigest? = nil,
        after: ContentDigest? = nil
    ) {
        self.path = path
        self.classification = classification
        self.before = before
        self.after = after
    }
}

/// Digests that must be compared independently to detect evaluation gaming.
public struct EvaluationIntegrityDigests:
    Codable,
    Equatable,
    Sendable
{
    public let subject: ContentDigest
    public let evaluationContract: ContentDigest
    public let execution: ContentDigest
    public let baseline: ContentDigest?

    public init(
        subject: ContentDigest,
        evaluationContract: ContentDigest,
        execution: ContentDigest,
        baseline: ContentDigest? = nil
    ) {
        self.subject = subject
        self.evaluationContract = evaluationContract
        self.execution = execution
        self.baseline = baseline
    }
}

public struct GitProvenanceEvidence:
    Codable,
    Equatable,
    Sendable
{
    public let repository: String?
    public let baseCommit: String
    public let candidateCommit: String?
    public let tree: String
    public let patch: ContentDigest?
    public let dirty: Bool

    public init(
        repository: String? = nil,
        baseCommit: String,
        candidateCommit: String? = nil,
        tree: String,
        patch: ContentDigest? = nil,
        dirty: Bool
    ) {
        self.repository = repository
        self.baseCommit = baseCommit
        self.candidateCommit = candidateCommit
        self.tree = tree
        self.patch = patch
        self.dirty = dirty
    }
}

public struct ToolchainProvenanceEvidence:
    Codable,
    Equatable,
    Sendable
{
    public let xcevalVersion: String
    public let xcevalBinary: ContentDigest
    public let swiftVersion: String?
    public let xcodeVersion: String?
    public let xcodeBuild: String?
    public let developerDirectory: String?
    public let operatingSystem: String?
    public let architecture: String?
    public let modelIdentifier: String?
    public let modelRuntime: String?

    public init(
        xcevalVersion: String,
        xcevalBinary: ContentDigest,
        swiftVersion: String? = nil,
        xcodeVersion: String? = nil,
        xcodeBuild: String? = nil,
        developerDirectory: String? = nil,
        operatingSystem: String? = nil,
        architecture: String? = nil,
        modelIdentifier: String? = nil,
        modelRuntime: String? = nil
    ) {
        self.xcevalVersion = xcevalVersion
        self.xcevalBinary = xcevalBinary
        self.swiftVersion = swiftVersion
        self.xcodeVersion = xcodeVersion
        self.xcodeBuild = xcodeBuild
        self.developerDirectory = developerDirectory
        self.operatingSystem = operatingSystem
        self.architecture = architecture
        self.modelIdentifier = modelIdentifier
        self.modelRuntime = modelRuntime
    }
}

public struct RedactedEnvironmentVariable:
    Codable,
    Equatable,
    Sendable
{
    public enum Disclosure: String, Codable, Sendable {
        case plainText = "plain-text"
        case digest
        case presenceOnly = "presence-only"
    }

    public let name: String
    public let disclosure: Disclosure
    public let value: String?
    public let valueDigest: ContentDigest?

    public init(
        name: String,
        disclosure: Disclosure,
        value: String?,
        valueDigest: ContentDigest?
    ) {
        self.name = name
        self.disclosure = disclosure
        self.value = value
        self.valueDigest = valueDigest
    }
}

/// Records which environment values were present without leaking secrets.
public struct RedactedEnvironmentDescriptor:
    Codable,
    Equatable,
    Sendable
{
    public let variables: [RedactedEnvironmentVariable]

    public init(
        environment: [String: String],
        revealValuesFor allowedNames: Set<String> = []
    ) {
        variables = environment.keys.sorted().map { name in
            let value = environment[name] ?? ""
            let sensitive = Self.isSensitive(name)
            let mayReveal =
                allowedNames.contains(name)
                && !sensitive
            return RedactedEnvironmentVariable(
                name: name,
                disclosure: sensitive
                    ? .presenceOnly
                    : mayReveal ? .plainText : .digest,
                value: mayReveal ? value : nil,
                valueDigest: mayReveal || sensitive
                    ? nil
                    : ContentDigest(data: Data(value.utf8))
            )
        }
    }

    public static func isSensitive(_ name: String) -> Bool {
        let normalized = name.uppercased()
        let fragments = [
            "AUTH",
            "COOKIE",
            "CREDENTIAL",
            "KEY",
            "PASSWORD",
            "SECRET",
            "SESSION",
            "TOKEN"
        ]
        return fragments.contains { normalized.contains($0) }
    }
}

public enum ProvenanceArtifactRole: String, Codable, Sendable {
    case input
    case nativeResult = "native-result"
    case derivedReport = "derived-report"
    case log
    case approval
}

public struct ProvenanceArtifact:
    Codable,
    Equatable,
    Sendable
{
    public let role: ProvenanceArtifactRole
    public let reference: ContentAddressedReference
    public let path: String?

    public init(
        role: ProvenanceArtifactRole,
        reference: ContentAddressedReference,
        path: String? = nil
    ) {
        self.role = role
        self.reference = reference
        self.path = path
    }
}

public struct EvaluationProvenanceManifest:
    Codable,
    Equatable,
    Sendable
{
    public static let currentSchemaVersion = "xceval.provenance/v1"

    public let schemaVersion: String
    public let runID: String
    public let createdAt: Date
    public let integrity: EvaluationIntegrityDigests
    public let git: GitProvenanceEvidence
    public let toolchain: ToolchainProvenanceEvidence
    public let environment: RedactedEnvironmentDescriptor
    public let mutations: [ProvenanceMutation]
    public let artifacts: [ProvenanceArtifact]

    public init(
        schemaVersion: String = Self.currentSchemaVersion,
        runID: String,
        createdAt: Date,
        integrity: EvaluationIntegrityDigests,
        git: GitProvenanceEvidence,
        toolchain: ToolchainProvenanceEvidence,
        environment: RedactedEnvironmentDescriptor,
        mutations: [ProvenanceMutation] = [],
        artifacts: [ProvenanceArtifact] = []
    ) {
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.createdAt = createdAt
        self.integrity = integrity
        self.git = git
        self.toolchain = toolchain
        self.environment = environment
        self.mutations = mutations
        self.artifacts = artifacts
    }
}
