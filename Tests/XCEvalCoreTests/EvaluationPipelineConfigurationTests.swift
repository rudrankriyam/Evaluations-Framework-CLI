import Foundation
import Testing

@testable import XCEvalCore

@Test("Pipeline manifests decode stable defaults")
func decodesPipelineDefaults() throws {
    let configuration = try JSONDecoder().decode(
        EvaluationPipelineConfiguration.self,
        from: Data(
            #"""
            {
              "schemaVersion": "xceval.pipeline/v1",
              "name": "Starter",
              "resultsPath": ".xceval/results"
            }
            """#.utf8
        )
    )

    try configuration.validate()
    #expect(configuration.workingDirectory == ".")
    #expect(configuration.artifactsDirectory == ".xceval/pipeline")
    #expect(configuration.steps.isEmpty)
    #expect(configuration.gates.isEmpty)
    #expect(!configuration.requiresEvaluationsXcode)
}

@Test("Pipeline manifests reject duplicate stages and invalid gates")
func validatesPipelineConfiguration() throws {
    let duplicate = EvaluationPipelineConfiguration(
        name: "Duplicate",
        resultsPath: "results",
        steps: [
            EvaluationPipelineStep(name: "run", command: ["/usr/bin/true"]),
            EvaluationPipelineStep(name: "run", command: ["/usr/bin/true"])
        ]
    )
    #expect(
        throws: EvaluationPipelineConfigurationError.duplicateStepName("run")
    ) {
        try duplicate.validate()
    }

    let invalidGate = EvaluationPipelineConfiguration(
        name: "Gate",
        resultsPath: "results",
        gates: ["Accuracy is good"]
    )
    #expect(throws: EvaluationPipelineConfigurationError.self) {
        try invalidGate.validate()
    }
}
