import Foundation

public enum EvaluationAuthoringRecipeKind:
    String,
    CaseIterable,
    Codable,
    Sendable
{
    case deterministic
    case modelJudge = "model-judge"
    case session
    case synthetic
    case toolCall = "tool-call"
}

public struct EvaluationAuthoringRequirement:
    Codable,
    Equatable,
    Sendable
{
    public let module: String
    public let symbol: String
    public let purpose: String

    public init(module: String, symbol: String, purpose: String) {
        self.module = module
        self.symbol = symbol
        self.purpose = purpose
    }
}

public struct EvaluationAuthoringSemanticInput:
    Codable,
    Equatable,
    Sendable
{
    public let id: String
    public let description: String

    public init(id: String, description: String) {
        self.id = id
        self.description = description
    }
}

public struct EvaluationAuthoringCompilationPlan:
    Codable,
    Equatable,
    Sendable
{
    public let mode: String
    public let platform: String
    public let requiredOSVersion: String
    public let requiredFrameworks: [String]

    public init(
        mode: String = "swift-typecheck",
        platform: String = "macOS",
        requiredOSVersion: String = "27.0",
        requiredFrameworks: [String] = ["Evaluations", "FoundationModels"]
    ) {
        self.mode = mode
        self.platform = platform
        self.requiredOSVersion = requiredOSVersion
        self.requiredFrameworks = requiredFrameworks
    }
}

public struct EvaluationAuthoringTemplate:
    Codable,
    Equatable,
    Sendable
{
    public static let typeNameToken = "__XCEVAL_TYPE__"

    public let relativePath: String
    public let defaultTypeName: String
    public let sourceTemplate: String

    public init(
        relativePath: String,
        defaultTypeName: String,
        sourceTemplate: String
    ) {
        self.relativePath = relativePath
        self.defaultTypeName = defaultTypeName
        self.sourceTemplate = sourceTemplate
    }

    public func render(typeName: String? = nil) throws -> String {
        let resolvedName = typeName ?? defaultTypeName
        guard Self.isSwiftIdentifier(resolvedName) else {
            throw EvaluationAuthoringRecipeError.invalidTypeName(resolvedName)
        }
        return sourceTemplate.replacingOccurrences(
            of: Self.typeNameToken,
            with: resolvedName
        )
    }

    private static func isSwiftIdentifier(_ value: String) -> Bool {
        guard
            let first = value.first,
            first == "_" || first.isLetter,
            first.isASCII
        else {
            return false
        }
        return value.dropFirst().allSatisfy {
            $0.isASCII && ($0 == "_" || $0.isLetter || $0.isNumber)
        }
    }
}

public struct EvaluationAuthoringRecipe:
    Codable,
    Equatable,
    Sendable
{
    public let id: String
    public let kind: EvaluationAuthoringRecipeKind
    public let summary: String
    public let requirements: [EvaluationAuthoringRequirement]
    public let semanticInputs: [EvaluationAuthoringSemanticInput]
    public let template: EvaluationAuthoringTemplate
    public let compilationPlan: EvaluationAuthoringCompilationPlan

    public init(
        id: String,
        kind: EvaluationAuthoringRecipeKind,
        summary: String,
        requirements: [EvaluationAuthoringRequirement],
        semanticInputs: [EvaluationAuthoringSemanticInput],
        template: EvaluationAuthoringTemplate,
        compilationPlan: EvaluationAuthoringCompilationPlan =
            EvaluationAuthoringCompilationPlan()
    ) {
        self.id = id
        self.kind = kind
        self.summary = summary
        self.requirements = requirements
        self.semanticInputs = semanticInputs
        self.template = template
        self.compilationPlan = compilationPlan
    }
}

public enum EvaluationAuthoringRecipeError: LocalizedError, Equatable {
    case invalidTypeName(String)

    public var errorDescription: String? {
        switch self {
        case .invalidTypeName(let name):
            "'\(name)' is not a supported Swift type identifier."
        }
    }
}

public enum EvaluationAuthoringRecipeCatalog {
    public static let recipes: [EvaluationAuthoringRecipe] = [
        deterministic,
        modelJudge,
        toolCall,
        synthetic,
        session
    ]

    public static func recipe(
        for kind: EvaluationAuthoringRecipeKind
    ) -> EvaluationAuthoringRecipe {
        switch kind {
        case .deterministic:
            deterministic
        case .modelJudge:
            modelJudge
        case .session:
            session
        case .synthetic:
            synthetic
        case .toolCall:
            toolCall
        }
    }

    public static func validateRequirements(
        against catalog: EvaluationsAPICatalog
    ) -> [EvaluationAuthoringRequirement] {
        recipes.flatMap(\.requirements).filter {
            $0.module == "Evaluations"
                && catalog.symbol(named: $0.symbol) == nil
        }
    }

    private static let evaluationRequirements = [
        requirement("Evaluation", "Defines the typed evaluation lifecycle."),
        requirement("ArrayLoader", "Loads explicit in-memory samples."),
        requirement("ModelSample", "Carries prompts and expected values."),
        requirement("ModelSubject", "Carries the produced value and transcript."),
        requirement("Evaluator", "Runs deterministic metric logic."),
        requirement("Metric", "Represents pass, fail, score, or ignore output."),
        requirement("MetricsAggregator", "Declares aggregate calculations.")
    ]

    private static let deterministic = EvaluationAuthoringRecipe(
        id: "xceval.recipe/deterministic/v1",
        kind: .deterministic,
        summary: """
            Injects samples, subject behavior, and criteria into a typed \
            deterministic evaluation without selecting product semantics.
            """,
        requirements: evaluationRequirements,
        semanticInputs: [
            input("dataset", "Representative samples and expected values."),
            input("subject", "The feature behavior to execute for each sample."),
            input("criteria", "Computable product-specific correctness criteria."),
            input("aggregation", "Explicit aggregate calculations and gates.")
        ],
        template: EvaluationAuthoringTemplate(
            relativePath: "Sources/__XCEVAL_TYPE__.swift",
            defaultTypeName: "DeterministicRecipeEvaluation",
            sourceTemplate: deterministicSource
        )
    )

    private static let modelJudge = EvaluationAuthoringRecipe(
        id: "xceval.recipe/model-judge/v1",
        kind: .modelJudge,
        summary: """
            Wires an explicitly supplied judge, dimensions, samples, and subject \
            behavior into ModelJudgeEvaluator.
            """,
        requirements: evaluationRequirements + [
            requirement("ModelJudgeEvaluator", "Scores explicit dimensions."),
            requirement("ScoreDimension", "Names one subjective criterion."),
            requirement("ScoringScale", "Defines allowed score values.")
        ] + [
            requirement(
                "LanguageModel",
                "Supplies the explicitly selected judge model.",
                module: "FoundationModels"
            )
        ],
        semanticInputs: [
            input("dataset", "Representative samples and reference values."),
            input("subject", "The feature output that the judge will score."),
            input("judge", "The model and credentials used for judging."),
            input("dimensions", "Human-defined criteria, scales, and guidance."),
            input("calibration", "Human labels used to validate judge behavior.")
        ],
        template: EvaluationAuthoringTemplate(
            relativePath: "Sources/__XCEVAL_TYPE__.swift",
            defaultTypeName: "ModelJudgeRecipeEvaluation",
            sourceTemplate: modelJudgeSource
        )
    )

    private static let toolCall = EvaluationAuthoringRecipe(
        id: "xceval.recipe/tool-call/v1",
        kind: .toolCall,
        summary: """
            Wires explicit trajectory expectations and captured transcripts into \
            ToolCallEvaluator without inventing tool relationships.
            """,
        requirements: evaluationRequirements + [
            requirement("ArgumentMatcher", "Matches explicit tool arguments."),
            requirement("StructuredTranscript", "Carries observed tool calls."),
            requirement("ToolCallEvaluator", "Evaluates expected trajectories."),
            requirement("ToolExpectation", "Defines an expected tool call."),
            requirement(
                "TrajectoryExpectation",
                "Defines ordered, unordered, and disallowed calls."
            )
        ],
        semanticInputs: [
            input("tools", "The application's actual tool schemas."),
            input("expectations", "Allowed, required, and disallowed calls."),
            input("arguments", "Explicit argument matching policies."),
            input("transcript", "The observed native transcript evidence."),
            input("lineage", "Only relationships evidenced by the producer.")
        ],
        template: EvaluationAuthoringTemplate(
            relativePath: "Sources/__XCEVAL_TYPE__.swift",
            defaultTypeName: "ToolCallRecipeEvaluation",
            sourceTemplate: toolCallSource
        )
    )

    private static let synthetic = EvaluationAuthoringRecipe(
        id: "xceval.recipe/synthetic/v1",
        kind: .synthetic,
        summary: """
            Wraps SampleGenerator with explicitly supplied seed samples, \
            generation prompt, session provider, target count, and validator.
            """,
        requirements: [
            requirement("ModelSample", "Defines generated sample values."),
            requirement("SampleGenerator", "Generates candidate samples.")
        ] + [
            requirement(
                "LanguageModelSession",
                "Runs the explicitly supplied generation model.",
                module: "FoundationModels"
            ),
            requirement(
                "Prompt",
                "Carries the explicit synthetic-generation request.",
                module: "FoundationModels"
            )
        ],
        semanticInputs: [
            input("seeds", "Curated seed samples."),
            input("prompt", "The requested dataset expansion behavior."),
            input("model", "The session provider and model configuration."),
            input("target-count", "The requested candidate sample count."),
            input("validator", "Product-specific acceptance logic.")
        ],
        template: EvaluationAuthoringTemplate(
            relativePath: "Sources/__XCEVAL_TYPE__.swift",
            defaultTypeName: "SyntheticRecipe",
            sourceTemplate: syntheticSource
        )
    )

    private static let session = EvaluationAuthoringRecipe(
        id: "xceval.recipe/session/v1",
        kind: .session,
        summary: """
            Runs an explicitly supplied LanguageModelSession factory and records \
            its native transcript in each ModelSubject.
            """,
        requirements: evaluationRequirements + [
            requirement(
                "StructuredTranscript",
                "Projects the native session transcript."
            )
        ] + [
            requirement(
                "LanguageModelSession",
                "Executes the explicitly configured feature session.",
                module: "FoundationModels"
            )
        ],
        semanticInputs: [
            input("dataset", "Representative prompts and expected values."),
            input("session", "Model, tools, instructions, and runtime controls."),
            input("criteria", "Deterministic criteria for the returned content."),
            input("permissions", "App-owned confirmation and permission behavior.")
        ],
        template: EvaluationAuthoringTemplate(
            relativePath: "Sources/__XCEVAL_TYPE__.swift",
            defaultTypeName: "SessionRecipeEvaluation",
            sourceTemplate: sessionSource
        )
    )

    private static func requirement(
        _ symbol: String,
        _ purpose: String,
        module: String = "Evaluations"
    ) -> EvaluationAuthoringRequirement {
        EvaluationAuthoringRequirement(
            module: module,
            symbol: symbol,
            purpose: purpose
        )
    }

    private static func input(
        _ id: String,
        _ description: String
    ) -> EvaluationAuthoringSemanticInput {
        EvaluationAuthoringSemanticInput(id: id, description: description)
    }

    private static let deterministicSource = #"""
        import Evaluations
        import Foundation

        @available(macOS 27.0, *)
        public struct __XCEVAL_TYPE__: Evaluation {
            public typealias SubjectProvider =
                @Sendable (ModelSample<String>) async throws -> ModelSubject<String>
            public typealias Criterion =
                @Sendable (ModelSample<String>, ModelSubject<String>) async throws
                    -> Metric

            public let metric: Metric
            public let dataset: ArrayLoader<ModelSample<String>>
            private let subjectProvider: SubjectProvider
            private let criterion: Criterion

            public init(
                samples: [ModelSample<String>],
                metric: Metric,
                subjectProvider: @escaping SubjectProvider,
                criterion: @escaping Criterion
            ) {
                dataset = ArrayLoader(samples: samples)
                self.metric = metric
                self.subjectProvider = subjectProvider
                self.criterion = criterion
            }

            public func subject(
                from sample: ModelSample<String>
            ) async throws -> ModelSubject<String> {
                try await subjectProvider(sample)
            }

            public var evaluators: Evaluators {
                Evaluator { sample, subject in
                    try await criterion(sample, subject)
                }
            }

            public func aggregateMetrics(
                using aggregator: inout MetricsAggregator
            ) {
                aggregator.computeMean(of: metric)
            }
        }
        """#

    private static let modelJudgeSource = #"""
        import Evaluations
        import Foundation
        import FoundationModels

        @available(macOS 27.0, *)
        public struct __XCEVAL_TYPE__: Evaluation {
            public typealias SubjectProvider =
                @Sendable (ModelSample<String>) async throws -> ModelSubject<String>

            public let dataset: ArrayLoader<ModelSample<String>>
            public let dimensions: [ScoreDimension]
            private let judge: any LanguageModel
            private let subjectProvider: SubjectProvider

            public init(
                samples: [ModelSample<String>],
                judge: any LanguageModel,
                dimensions: [ScoreDimension],
                subjectProvider: @escaping SubjectProvider
            ) {
                dataset = ArrayLoader(samples: samples)
                self.judge = judge
                self.dimensions = dimensions
                self.subjectProvider = subjectProvider
            }

            public func subject(
                from sample: ModelSample<String>
            ) async throws -> ModelSubject<String> {
                try await subjectProvider(sample)
            }

            public var evaluators: Evaluators {
                ModelJudgeEvaluator(
                    judge: judge,
                    dimensions: dimensions
                )
            }

            public func aggregateMetrics(
                using aggregator: inout MetricsAggregator
            ) {
                for dimension in dimensions {
                    aggregator.computeMean(of: dimension.metric)
                }
            }
        }
        """#

    private static let toolCallSource = #"""
        import Evaluations
        import Foundation

        @available(macOS 27.0, *)
        public struct __XCEVAL_TYPE__: Evaluation {
            public typealias SubjectProvider =
                @Sendable (ModelSample<String>) async throws -> ModelSubject<String>

            public let allPass: Metric
            public let percentagePass: Metric
            public let dataset: ArrayLoader<ModelSample<String>>
            private let subjectProvider: SubjectProvider

            public init(
                samples: [ModelSample<String>],
                allPass: Metric,
                percentagePass: Metric,
                subjectProvider: @escaping SubjectProvider
            ) {
                dataset = ArrayLoader(samples: samples)
                self.allPass = allPass
                self.percentagePass = percentagePass
                self.subjectProvider = subjectProvider
            }

            public func subject(
                from sample: ModelSample<String>
            ) async throws -> ModelSubject<String> {
                try await subjectProvider(sample)
            }

            public var evaluators: Evaluators {
                ToolCallEvaluator(
                    allPass: allPass,
                    percentagePass: percentagePass
                )
            }

            public func aggregateMetrics(
                using aggregator: inout MetricsAggregator
            ) {
                aggregator.computeMean(of: allPass)
                aggregator.computeMean(of: percentagePass)
            }
        }
        """#

    private static let syntheticSource = #"""
        import Evaluations
        import FoundationModels

        @available(macOS 27.0, *)
        public enum __XCEVAL_TYPE__ {
            public static func samples(
                prompt: Prompt,
                seeds: [ModelSample<String>],
                targetCount: Int,
                sessionProvider: @escaping @Sendable () -> LanguageModelSession,
                validator: @escaping @Sendable (ModelSample<String>) async throws
                    -> Bool
            ) -> some AsyncSequence<ModelSample<String>, any Error> {
                let generator = SampleGenerator(
                    prompt,
                    samples: seeds,
                    targetCount: targetCount,
                    sessionProvider: sessionProvider,
                    validator: validator
                )
                return generator.run()
            }
        }
        """#

    private static let sessionSource = #"""
        import Evaluations
        import Foundation
        import FoundationModels

        @available(macOS 27.0, *)
        public struct __XCEVAL_TYPE__: Evaluation {
            public typealias SessionProvider =
                @Sendable () -> LanguageModelSession
            public typealias Criterion =
                @Sendable (ModelSample<String>, ModelSubject<String>) async throws
                    -> Metric

            public let metric: Metric
            public let dataset: ArrayLoader<ModelSample<String>>
            private let sessionProvider: SessionProvider
            private let criterion: Criterion

            public init(
                samples: [ModelSample<String>],
                metric: Metric,
                sessionProvider: @escaping SessionProvider,
                criterion: @escaping Criterion
            ) {
                dataset = ArrayLoader(samples: samples)
                self.metric = metric
                self.sessionProvider = sessionProvider
                self.criterion = criterion
            }

            public func subject(
                from sample: ModelSample<String>
            ) async throws -> ModelSubject<String> {
                let session = sessionProvider()
                let response = try await session.respond(
                    to: sample.prompt
                )
                return ModelSubject(
                    value: response.content,
                    transcript: session.transcript.structuredTranscript
                )
            }

            public var evaluators: Evaluators {
                Evaluator { sample, subject in
                    try await criterion(sample, subject)
                }
            }

            public func aggregateMetrics(
                using aggregator: inout MetricsAggregator
            ) {
                aggregator.computeMean(of: metric)
            }
        }
        """#
}
