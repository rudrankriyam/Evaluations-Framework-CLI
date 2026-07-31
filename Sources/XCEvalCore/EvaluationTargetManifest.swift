import CryptoKit
import Foundation

public struct EvaluationTargetManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = "xceval.targets/v1"

    public let schemaVersion: String
    public let targets: [EvaluationTarget]

    public init(
        schemaVersion: String = Self.currentSchemaVersion,
        targets: [EvaluationTarget]
    ) {
        self.schemaVersion = schemaVersion
        self.targets = targets
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw EvaluationTargetManifestError.unsupportedSchema(schemaVersion)
        }
        guard !targets.isEmpty else {
            throw EvaluationTargetManifestError.emptyTargets
        }

        var identifiers = Set<String>()
        for target in targets {
            try target.validate()
            guard identifiers.insert(target.id).inserted else {
                throw EvaluationTargetManifestError.duplicateTarget(target.id)
            }
        }
    }

    public func target(id: String) throws -> EvaluationTarget {
        let matches = targets.filter { $0.id == id }
        guard let target = matches.first else {
            throw EvaluationTargetManifestError.targetNotFound(id)
        }
        guard matches.count == 1 else {
            throw EvaluationTargetManifestError.duplicateTarget(id)
        }
        return target
    }
}

public struct EvaluationTarget: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case command
        case xcodeTest = "xcode-test"
    }

    public let id: String
    public let kind: Kind
    public let workingDirectory: String?
    public let argv: [String]
    public let environment: EvaluationTargetEnvironment?
    public let outputs: [EvaluationTargetOutput]
    public let requirements: [EvaluationTargetRequirement]
    public let sampleKeyPointer: String?

    public init(
        id: String,
        kind: Kind = .command,
        workingDirectory: String? = nil,
        argv: [String],
        environment: EvaluationTargetEnvironment? = nil,
        outputs: [EvaluationTargetOutput],
        requirements: [EvaluationTargetRequirement] = [],
        sampleKeyPointer: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.workingDirectory = workingDirectory
        self.argv = argv
        self.environment = environment
        self.outputs = outputs
        self.requirements = requirements
        self.sampleKeyPointer = sampleKeyPointer
    }

    public var revision: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(self)) ?? Data()
        let digest = SHA256.hash(data: data)
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    public func validate() throws {
        let identifierPattern = /^[A-Za-z0-9][A-Za-z0-9._-]*$/
        guard id.wholeMatch(of: identifierPattern) != nil else {
            throw EvaluationTargetManifestError.invalidTargetID(id)
        }
        guard !argv.isEmpty,
            argv.allSatisfy({
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })
        else {
            throw EvaluationTargetManifestError.emptyCommand(id)
        }
        if let workingDirectory,
            workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        {
            throw EvaluationTargetManifestError.emptyWorkingDirectory(id)
        }
        guard !outputs.isEmpty else {
            throw EvaluationTargetManifestError.emptyOutputs(id)
        }
        for output in outputs {
            try output.validate(targetID: id)
        }
        if let sampleKeyPointer {
            guard sampleKeyPointer.isEmpty || sampleKeyPointer.hasPrefix("/") else {
                throw EvaluationTargetManifestError.invalidSampleKeyPointer(
                    id,
                    sampleKeyPointer
                )
            }
        }
    }

    public func resolvedEnvironment(
        from parent: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        guard let environment else { return [:] }
        var resolved: [String: String] = [:]
        for name in environment.inherit {
            if let value = parent[name] {
                resolved[name] = value
            }
        }
        resolved.merge(environment.set) { _, replacement in replacement }
        return resolved
    }
}

public struct EvaluationTargetEnvironment: Codable, Equatable, Sendable {
    public let inherit: [String]
    public let set: [String: String]

    public init(
        inherit: [String] = [],
        set: [String: String] = [:]
    ) {
        self.inherit = inherit
        self.set = set
    }
}

public struct EvaluationTargetOutput: Codable, Equatable, Sendable {
    public enum Format: String, Codable, CaseIterable, Sendable {
        case evaluationResult = "xcevalresult"
        case evaluationResultJSONLines = "xcevalresults-jsonl"
        case xcresult
    }

    public let role: String
    public let path: String
    public let format: Format
    public let minimumCount: Int?

    public init(
        role: String,
        path: String,
        format: Format = .evaluationResult,
        minimumCount: Int? = 1
    ) {
        self.role = role
        self.path = path
        self.format = format
        self.minimumCount = minimumCount
    }

    fileprivate func validate(targetID: String) throws {
        guard !role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EvaluationTargetManifestError.emptyOutputRole(targetID)
        }
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EvaluationTargetManifestError.emptyOutputPath(targetID)
        }
        if let minimumCount, minimumCount < 0 {
            throw EvaluationTargetManifestError.invalidMinimumCount(
                targetID,
                minimumCount
            )
        }
    }
}

public struct EvaluationTargetRequirement: Codable, Equatable, Sendable {
    public let capability: String
    public let minimumVersion: String?

    public init(capability: String, minimumVersion: String? = nil) {
        self.capability = capability
        self.minimumVersion = minimumVersion
    }
}

public enum EvaluationTargetManifestError: LocalizedError, Equatable {
    case unsupportedSchema(String)
    case emptyTargets
    case duplicateTarget(String)
    case targetNotFound(String)
    case invalidTargetID(String)
    case emptyCommand(String)
    case emptyWorkingDirectory(String)
    case emptyOutputs(String)
    case emptyOutputRole(String)
    case emptyOutputPath(String)
    case invalidMinimumCount(String, Int)
    case invalidSampleKeyPointer(String, String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let schema):
            "Unsupported target schema '\(schema)'. Expected "
                + "'\(EvaluationTargetManifest.currentSchemaVersion)'."
        case .emptyTargets:
            "The target manifest must declare at least one target."
        case .duplicateTarget(let id):
            "The target manifest contains duplicate target ID '\(id)'."
        case .targetNotFound(let id):
            "No evaluation target has ID '\(id)'."
        case .invalidTargetID(let id):
            "Target ID '\(id)' must contain only letters, numbers, '.', '_', "
                + "or '-' and start with a letter or number."
        case .emptyCommand(let id):
            "Target '\(id)' must declare a nonempty argv array."
        case .emptyWorkingDirectory(let id):
            "Target '\(id)' has an empty workingDirectory."
        case .emptyOutputs(let id):
            "Target '\(id)' must declare at least one output."
        case .emptyOutputRole(let id):
            "Target '\(id)' contains an output with an empty role."
        case .emptyOutputPath(let id):
            "Target '\(id)' contains an output with an empty path."
        case .invalidMinimumCount(let id, let count):
            "Target '\(id)' contains invalid minimumCount \(count)."
        case .invalidSampleKeyPointer(let id, let pointer):
            "Target '\(id)' has invalid sampleKeyPointer '\(pointer)'. "
                + "JSON Pointers must be empty or begin with '/'."
        }
    }
}
