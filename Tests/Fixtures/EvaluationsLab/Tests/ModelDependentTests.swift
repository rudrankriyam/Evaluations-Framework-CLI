import Evaluations
import EvaluationsLabSupport
import Foundation
import FoundationModels
import Testing

private let modelLanesEnabled =
    ProcessInfo.processInfo.environment["EVALUATIONS_LAB_RUN_MODEL_TESTS"] == "1"

@Suite("Explicitly gated model-dependent lanes")
struct ModelDependentTests {
    @Test(
        "Model judge evaluator",
        .enabled(if: modelLanesEnabled)
    )
    func modelJudge() async throws {
        let model = SystemLanguageModel()
        #expect(model.isAvailable, "The opt-in model lane requires an available system model")
        guard model.isAvailable else {
            return
        }

        let sample = ModelSample<String>(
            prompt: "What is two plus two?",
            expected: "Four"
        )
        let subject = ModelSubject(value: "Four")
        let evaluator = ModelJudgeEvaluator<ModelSample<String>>(
            "correctness",
            scale: .passFail(
                passDescription: "The response is correct.",
                failDescription: "The response is incorrect."
            ),
            judge: model
        )

        let metrics = try await evaluator.metrics(subject: subject, input: sample)
        #expect(metrics.count == 1)
    }

    @Test(
        "Natural-language argument matcher",
        .enabled(if: modelLanesEnabled)
    )
    func naturalLanguageMatcher() async throws {
        let model = SystemLanguageModel()
        #expect(model.isAvailable, "The opt-in model lane requires an available system model")
        guard model.isAvailable else {
            return
        }

        let sample = ModelSample<String>(
            prompt: "Use the weather tool.",
            expected: "It is 24 degrees in Paris.",
            expectations: TranscriptFixtures.naturalLanguageExpectation
        )
        let subject = ModelSubject(
            value: "It is 24 degrees in Paris.",
            transcript: TranscriptFixtures.structuredTranscript
        )
        let evaluator = ToolCallEvaluator<ModelSample<String>>(
            allPass: Metric("natural_language_all_pass"),
            percentagePass: Metric("natural_language_percentage"),
            argumentMatchModel: model
        )

        let metrics = try await evaluator.metrics(subject: subject, input: sample)
        #expect(metrics.count == 2)
    }

    @Test(
        "Sample generator",
        .enabled(if: modelLanesEnabled)
    )
    func sampleGenerator() async throws {
        let model = SystemLanguageModel()
        #expect(model.isAvailable, "The opt-in model lane requires an available system model")
        guard model.isAvailable else {
            return
        }

        let seed = ModelSample<String>(
            prompt: "What is one plus one?",
            expected: "Two"
        )
        let generator = SampleGenerator(
            Prompt("Create one additional elementary arithmetic sample."),
            samples: [seed],
            targetCount: 2,
            sessionProvider: {
                LanguageModelSession(model: model)
            },
            samplingStrategy: .random(retries: 2)
        )

        var generated: [ModelSample<String>] = []
        for try await sample in generator.run() {
            generated.append(sample)
        }

        #expect(generated.count >= 1)
        #expect(await generator.samples.count >= 1)
    }
}
