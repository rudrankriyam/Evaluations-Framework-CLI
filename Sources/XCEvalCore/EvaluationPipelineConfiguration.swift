import Foundation

public struct EvaluationPipelineSelection: Codable, Equatable, Sendable {
    public let evaluationID: String?
    public let resultID: String?

    public init(
        evaluationID: String? = nil,
        resultID: String? = nil
    ) {
        self.evaluationID = evaluationID
        self.resultID = resultID
    }
}

public struct EvaluationPipelineStep: Codable, Equatable, Sendable {
    public let name: String
    public let command: [String]
    public let environment: [String: String]

    public init(
        name: String,
        command: [String],
        environment: [String: String] = [:]
    ) {
        self.name = name
        self.command = command
        self.environment = environment
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case command
        case environment
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        command = try container.decode([String].self, forKey: .command)
        environment =
            try container.decodeIfPresent(
                [String: String].self,
                forKey: .environment
            ) ?? [:]
    }
}

public struct EvaluationPipelineConfiguration:
    Codable,
    Equatable,
    Sendable
{
    public static let currentSchemaVersion = "xceval.pipeline/v1"

    public let schemaVersion: String
    public let name: String
    public let workingDirectory: String
    public let artifactsDirectory: String
    public let resultsPath: String
    public let steps: [EvaluationPipelineStep]
    public let selection: EvaluationPipelineSelection?
    public let baseline: String?
    public let gates: [String]
    public let requiresEvaluationsXcode: Bool
    public let xcode: String?

    public init(
        schemaVersion: String = Self.currentSchemaVersion,
        name: String,
        workingDirectory: String = ".",
        artifactsDirectory: String = ".xceval/pipeline",
        resultsPath: String,
        steps: [EvaluationPipelineStep] = [],
        selection: EvaluationPipelineSelection? = nil,
        baseline: String? = nil,
        gates: [String] = [],
        requiresEvaluationsXcode: Bool = false,
        xcode: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.name = name
        self.workingDirectory = workingDirectory
        self.artifactsDirectory = artifactsDirectory
        self.resultsPath = resultsPath
        self.steps = steps
        self.selection = selection
        self.baseline = baseline
        self.gates = gates
        self.requiresEvaluationsXcode = requiresEvaluationsXcode
        self.xcode = xcode
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case name
        case workingDirectory
        case artifactsDirectory
        case resultsPath
        case steps
        case selection
        case baseline
        case gates
        case requiresEvaluationsXcode
        case xcode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(
            String.self,
            forKey: .schemaVersion
        )
        name = try container.decode(String.self, forKey: .name)
        workingDirectory =
            try container.decodeIfPresent(
                String.self,
                forKey: .workingDirectory
            ) ?? "."
        artifactsDirectory =
            try container.decodeIfPresent(
                String.self,
                forKey: .artifactsDirectory
            ) ?? ".xceval/pipeline"
        resultsPath = try container.decode(
            String.self,
            forKey: .resultsPath
        )
        steps =
            try container.decodeIfPresent(
                [EvaluationPipelineStep].self,
                forKey: .steps
            ) ?? []
        selection = try container.decodeIfPresent(
            EvaluationPipelineSelection.self,
            forKey: .selection
        )
        baseline = try container.decodeIfPresent(
            String.self,
            forKey: .baseline
        )
        gates =
            try container.decodeIfPresent(
                [String].self,
                forKey: .gates
            ) ?? []
        requiresEvaluationsXcode =
            try container.decodeIfPresent(
                Bool.self,
                forKey: .requiresEvaluationsXcode
            ) ?? false
        xcode = try container.decodeIfPresent(String.self, forKey: .xcode)
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw EvaluationPipelineConfigurationError.unsupportedSchema(
                schemaVersion
            )
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EvaluationPipelineConfigurationError.emptyName
        }
        guard
            !workingDirectory.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
        else {
            throw EvaluationPipelineConfigurationError.emptyWorkingDirectory
        }
        guard
            !artifactsDirectory.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
        else {
            throw EvaluationPipelineConfigurationError.emptyArtifactsDirectory
        }
        guard
            !resultsPath.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
        else {
            throw EvaluationPipelineConfigurationError.emptyResultsPath
        }

        var names = Set<String>()
        for step in steps {
            let name = step.name.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !name.isEmpty else {
                throw EvaluationPipelineConfigurationError.emptyStepName
            }
            guard names.insert(name).inserted else {
                throw EvaluationPipelineConfigurationError.duplicateStepName(
                    name
                )
            }
            guard
                !step.command.isEmpty,
                step.command.allSatisfy({
                    !$0.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
                })
            else {
                throw EvaluationPipelineConfigurationError.emptyStepCommand(
                    name
                )
            }
        }

        for gate in gates {
            do {
                _ = try EvaluationGateRule(gate)
            } catch {
                throw EvaluationPipelineConfigurationError.invalidGate(
                    gate,
                    error.localizedDescription
                )
            }
        }
    }
}

public enum EvaluationPipelineConfigurationError:
    LocalizedError,
    Equatable
{
    case unsupportedSchema(String)
    case emptyName
    case emptyWorkingDirectory
    case emptyArtifactsDirectory
    case emptyResultsPath
    case emptyStepName
    case duplicateStepName(String)
    case emptyStepCommand(String)
    case invalidGate(String, String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let value):
            """
            Unsupported pipeline schema '\(value)'. Expected \
            '\(EvaluationPipelineConfiguration.currentSchemaVersion)'.
            """
        case .emptyName:
            "Pipeline name must not be empty."
        case .emptyWorkingDirectory:
            "Pipeline workingDirectory must not be empty."
        case .emptyArtifactsDirectory:
            "Pipeline artifactsDirectory must not be empty."
        case .emptyResultsPath:
            "Pipeline resultsPath must not be empty."
        case .emptyStepName:
            "Pipeline step names must not be empty."
        case .duplicateStepName(let name):
            "Pipeline step name '\(name)' is duplicated."
        case .emptyStepCommand(let name):
            "Pipeline step '\(name)' must contain a nonempty command."
        case .invalidGate(let rule, let message):
            "Pipeline gate '\(rule)' is invalid: \(message)"
        }
    }
}
