import Evaluations
import Foundation
import FoundationModels

@available(macOS 27.0, *)
@Generable
struct AdvancedGenerableSample: Codable, ModelSampleProtocol, Sendable {
    var promptText: String
    var expectedText: String

    var input: ModelSampleInput {
        ModelSampleInput(prompt: Prompt(promptText))
    }

    var output: ModelSampleOutput<String, TrajectoryExpectation> {
        ModelSampleOutput(value: expectedText)
    }

    var expected: String? {
        expectedText
    }

    typealias Expectation = TrajectoryExpectation
}

@available(macOS 27.0, *)
enum AdvancedSampleGeneratorCoverage {
    // String already conforms to Generable in Foundation Models, so this
    // fixture exercises SampleGenerator without adding macro-expansion noise.
    static let seeds: [ModelSample<String>] = [
        ModelSample(
            prompt: "Summarize the first seed.",
            expected: "First seed"
        ),
        ModelSample(
            prompt: "Summarize the second seed.",
            expected: "Second seed"
        )
    ]

    static func randomGenerator(
        validator:
            @escaping @Sendable (
                ModelSample<String>
            ) async throws -> Bool = { _ in true }
    ) -> SampleGenerator<ModelSample<String>> {
        SampleGenerator(
            Prompt(
                "Generate diverse evaluation samples matching the seed format."
            ),
            samples: seeds,
            targetCount: 4,
            samplingStrategy: .random(retries: 2),
            validator: validator
        )
    }

    static func slidingWindowGenerator(
        validator:
            @escaping @Sendable (
                ModelSample<String>
            ) async throws -> Bool = { _ in true }
    ) -> SampleGenerator<ModelSample<String>> {
        SampleGenerator(
            Prompt(
                "Generate boundary cases related to each adjacent seed window."
            ),
            samples: seeds,
            targetCount: 4,
            samplingStrategy: .slidingWindow,
            validator: validator
        )
    }

    static func rejectingGenerator()
        -> SampleGenerator<ModelSample<String>>
    {
        randomGenerator { _ in
            // An opt-in runtime test exercises invalidSamples using this
            // validator. Merely constructing the generator never invokes a
            // language model.
            false
        }
    }

    static func modelSampleMakeSamples(
        model: SystemLanguageModel = .default
    ) -> some AsyncSequence<ModelSample<String>, any Error> {
        seeds.makeSamples(
            Prompt("Generate one more sample through the ModelSample overload."),
            targetCount: 3,
            sessionProvider: {
                LanguageModelSession(model: model)
            },
            validator: { sample in
                !sample.promptDescription.isEmpty
            }
        )
    }

    static let generableSeeds: [AdvancedGenerableSample] = [
        AdvancedGenerableSample(
            promptText: "Name a primary color.",
            expectedText: "Red"
        ),
        AdvancedGenerableSample(
            promptText: "Name a secondary color.",
            expectedText: "Purple"
        )
    ]

    static func generableSampleMakeSamples(
        model: SystemLanguageModel = .default
    ) -> some AsyncSequence<AdvancedGenerableSample, any Error> {
        generableSeeds.makeSamples(
            Prompt(
                "Generate one more sample through the generic Generable overload."
            ),
            targetCount: 3,
            sessionProvider: {
                LanguageModelSession(model: model)
            },
            validator: { sample in
                !sample.promptText.isEmpty && !sample.expectedText.isEmpty
            }
        )
    }
}

@available(macOS 27.0, *)
enum AdvancedToolEvaluationCoverage {
    static let allPass = Metric("Tools All Pass")
    static let percentagePass = Metric("Tools Percentage Pass")

    static let matcherVariants: [ArgumentMatcher] = [
        .exact(argumentName: "city", value: .string("Cupertino")),
        .keyOnly(argumentName: "requestID"),
        .oneOf(
            argumentName: "units",
            allowedValues: [.string("metric"), .string("imperial")]
        ),
        .range(argumentName: "days", minimum: 1, maximum: 10),
        .pattern(
            argumentName: "postalCode",
            regex: #"^[0-9]{5}(?:-[0-9]{4})?$"#
        ),
        .contains(argumentName: "query", substring: "weather"),
        .hasPrefix(argumentName: "path", prefix: "/v1/"),
        .hasSuffix(argumentName: "filename", suffix: ".json"),
        .naturalLanguage(
            argumentName: "summary",
            criteria: "A concise summary of current weather conditions."
        )
    ]

    static let orderedWithAnyOrder = TrajectoryExpectation(
        ordered: [
            ToolExpectation(
                "authenticate",
                arguments: [.keyOnly(argumentName: "token")]
            ),
            .anyOrder([
                ToolExpectation(
                    "fetch_weather",
                    arguments: [
                        .exact(
                            argumentName: "city",
                            value: .string("Cupertino")
                        )
                    ]
                ),
                ToolExpectation(
                    "fetch_alerts",
                    arguments: [
                        .oneOf(
                            argumentName: "severity",
                            allowedValues: [.string("warning"), .string("critical")]
                        )
                    ]
                )
            ]),
            ToolExpectation("present_results")
        ],
        allowsAdditionalToolCalls: false
    )

    static let unordered = TrajectoryExpectation(
        unordered: [
            ToolExpectation("fetch_weather"),
            ToolExpectation("fetch_alerts"),
            ToolExpectation("fetch_air_quality")
        ]
    )

    static let disallowed = TrajectoryExpectation(
        ordered: [ToolExpectation("read_forecast")],
        unordered: [ToolExpectation("read_alerts")],
        disallowed: [
            ToolExpectation("delete_location"),
            ToolExpectation(
                "update_location",
                arguments: [
                    .exact(argumentName: "permission", value: .string("denied"))
                ]
            )
        ]
    )

    static let allowsAdditionalCalls = TrajectoryExpectation(
        ordered: [ToolExpectation("fetch_weather")],
        unordered: [ToolExpectation("fetch_alerts")],
        allowsAdditionalToolCalls: true
    )

    static let rejectsAdditionalCalls = TrajectoryExpectation(
        ordered: [ToolExpectation("fetch_weather")],
        unordered: [ToolExpectation("fetch_alerts")],
        allowsAdditionalToolCalls: false
    )

    static let singleTool = TrajectoryExpectation(
        expected: "fetch_weather",
        arguments: matcherVariants
    )

    static let deterministicEvaluator =
        ToolCallEvaluator<ModelSample<String>>(
            allPass: allPass,
            percentagePass: percentagePass
        )

    // The explicit judge constructor is required for naturalLanguage argument
    // matching. Constructing it is compile coverage only and does not run the
    // model.
    static let semanticArgumentEvaluator =
        ToolCallEvaluator<ModelSample<String>>(
            allPass: allPass,
            percentagePass: percentagePass,
            argumentMatchModel: SystemLanguageModel.default
        )

    static func transcript(
        toolName: String,
        argumentsJSON: String
    ) throws -> StructuredTranscript {
        StructuredTranscript(
            toolCalls: [
                Transcript.ToolCall(
                    id: "advanced-coverage-call",
                    toolName: toolName,
                    arguments: try GeneratedContent(json: argumentsJSON)
                )
            ],
            toolOutputs: [],
            instructionText: "Use tools when needed.",
            prompts: ["Run the advanced tool coverage scenario."],
            responses: []
        )
    }
}
