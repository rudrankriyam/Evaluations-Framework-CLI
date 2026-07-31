import Foundation
import Testing
import XCEvalFormat

@Test("Plan documents expose read-only paths and provenance")
func decodesPlanDocument() throws {
    let document = try XCEvalDocumentDecoder.decode(
        discoveryJSON(
            """
            {
              "schemaVersion":"xceval.plan/v1",
              "command":"plan",
              "readOnly":true,
              "run":{
                "runID":"candidate-1",
                "runsRoot":"file:///tmp/runs/",
                "runDirectory":"file:///tmp/runs/candidate-1/",
                "artifactsDirectory":"file:///tmp/runs/candidate-1/artifacts/",
                "logsDirectory":"file:///tmp/runs/candidate-1/logs/",
                "provenanceFile":"file:///tmp/runs/candidate-1/provenance.json",
                "eventsFile":"file:///tmp/runs/candidate-1/events.jsonl"
              },
              "provenance":{
                "schemaVersion":"xceval.provenance/v1",
                "runID":"candidate-1",
                "createdAt":"2026-07-31T00:00:00Z",
                "environment":{"variables":[{
                  "name":"TOKEN",
                  "disclosure":"presence-only"
                }]},
                "mutations":[],
                "artifacts":[],
                "requiredEvidence":["integrity.subject"]
              }
            }
            """
        )
    )
    guard case .plan(let plan) = document else {
        Issue.record("Expected a plan document.")
        return
    }

    #expect(plan.readOnly)
    #expect(plan.run.runID == "candidate-1")
    #expect(
        plan.provenance.environment.variables.first?.disclosure
            == .presenceOnly
    )
}

@Test("Evaluations API catalog list and show documents decode")
func decodesAPICatalogDocuments() throws {
    let source =
        """
        {"xcodeVersion":"27.0","xcodeBuild":"17A1",
        "frameworkPath":"/Xcode/Evaluations.framework",
        "interfacePath":"/Xcode/Evaluations.swiftinterface",
        "architecture":"arm64","targetTriple":"arm64-apple-macos27.0",
        "compilerVersion":"Swift 6","moduleName":"Evaluations"}
        """
    let location =
        #"{"path":"/Xcode/Evaluations.swiftinterface","startLine":10,"endLine":20}"#
    let availability =
        #"{"platform":"macOS","introducedVersion":"27.0","isUnavailable":false,"rawAttribute":"@available(macOS 27.0, *)"}"#

    let list = try XCEvalDocumentDecoder.decode(
        discoveryJSON(
            """
            {
              "schemaVersion":"xceval.evaluations-api/v1",
              "command":"api list",
              "source":\(source),
              "count":1,
              "symbols":[{
                "name":"Evaluation",
                "kind":"struct",
                "availability":[\(availability)],
                "sourceLocation":\(location)
              }]
            }
            """
        )
    )
    guard case .apiList(let catalog) = list else {
        Issue.record("Expected an API list document.")
        return
    }
    #expect(catalog.symbols.first?.kind == .struct)

    let show = try XCEvalDocumentDecoder.decode(
        discoveryJSON(
            """
            {
              "schemaVersion":"xceval.evaluations-api/v1",
              "command":"api show",
              "source":\(source),
              "symbol":{
                "name":"Evaluation",
                "kind":"struct",
                "declaration":"public struct Evaluation {}",
                "availability":[\(availability)],
                "sourceLocation":\(location)
              }
            }
            """
        )
    )
    guard case .apiShow(let detail) = show else {
        Issue.record("Expected an API show document.")
        return
    }
    #expect(detail.symbol.declaration.contains("struct Evaluation"))
}

@Test("Authoring example and verification documents decode")
func decodesAuthoringDocuments() throws {
    let example = try XCEvalDocumentDecoder.decode(
        discoveryJSON(
            """
            {
              "schemaVersion":"xceval.authoring-example/v1",
              "command":"api example",
              "recipe":{
                "id":"xceval.recipe/deterministic/v1",
                "kind":"deterministic",
                "summary":"A deterministic recipe.",
                "requirements":[{
                  "module":"Evaluations",
                  "symbol":"Evaluation",
                  "purpose":"Defines evaluation."
                }],
                "semanticInputs":[{
                  "id":"dataset",
                  "description":"Representative samples."
                }],
                "template":{
                  "relativePath":"Sources/__XCEVAL_TYPE__.swift",
                  "defaultTypeName":"ExampleEvaluation",
                  "sourceTemplate":"struct __XCEVAL_TYPE__ {}"
                },
                "compilationPlan":{
                  "mode":"swift-typecheck",
                  "platform":"macOS",
                  "requiredOSVersion":"27.0",
                  "requiredFrameworks":["Evaluations","FoundationModels"]
                }
              },
              "typeName":"ExampleEvaluation",
              "source":"struct ExampleEvaluation {}"
            }
            """
        )
    )
    guard case .apiExample(let rendered) = example else {
        Issue.record("Expected an API example document.")
        return
    }
    #expect(rendered.recipe.kind == .deterministic)

    let verify = try XCEvalDocumentDecoder.decode(
        discoveryJSON(
            """
            {
              "schemaVersion":"xceval.authoring-verification/v1",
              "command":"api verify",
              "xcode":\(discoveryXcode),
              "passed":true,
              "results":[{
                "recipeID":"xceval.recipe/deterministic/v1",
                "passed":true,
                "xcodeVersion":"27.0",
                "xcodeBuild":"17A1",
                "interfacePath":"/Xcode/Evaluations.swiftinterface",
                "command":["/usr/bin/xcrun","swiftc"],
                "diagnostics":""
              }]
            }
            """
        )
    )
    guard case .apiVerify(let verification) = verify else {
        Issue.record("Expected an API verification document.")
        return
    }
    #expect(verification.passed)
    #expect(verification.results.first?.command.last == "swiftc")
}

@Test("Evidence documents decode stable sample comparison contracts")
func decodesEvidenceDocument() throws {
    let document = try XCEvalDocumentDecoder.decode(
        discoveryJSON(
            """
            {
              "schemaVersion":"xceval/v1",
              "command":"evidence",
              "artifact":\(discoveryArtifact),
              "baseline":null,
              "sampleKeyStrategy":{"canonicalInputDigest":{}},
              "includesStructuralDifferences":true,
              "regressionsOnly":false,
              "failingSamples":[],
              "aggregateDeltas":[],
              "sampleDeltas":[]
            }
            """
        )
    )
    guard case .evidence(let evidence) = document else {
        Issue.record("Expected an evidence document.")
        return
    }

    #expect(evidence.includesStructuralDifferences)
    #expect(evidence.artifact.artifactID == "artifact-1")
    #expect(evidence.sampleKeyStrategy == .canonicalInputDigest)
}

@Test("Gate documents decode additive baseline and delta rules")
func decodesDeltaGateDocument() throws {
    let document = try XCEvalDocumentDecoder.decode(
        discoveryJSON(
            """
            {
              "schemaVersion":"xceval/v1",
              "command":"gate",
              "artifact":\(discoveryArtifact),
              "baseline":\(discoveryArtifact),
              "passed":false,
              "rules":[],
              "deltaRules":[{
                "expression":"Mean of Accuracy>=0.1",
                "resolvedMetric":"Mean of Accuracy",
                "baseline":0.5,
                "candidate":0.55,
                "delta":0.05,
                "expected":0.1,
                "comparison":">=",
                "passed":false
              }]
            }
            """
        )
    )
    guard case .gate(let gate) = document else {
        Issue.record("Expected a gate document.")
        return
    }

    #expect(gate.baseline?.byteDigest == "sha256:bytes")
    #expect(gate.deltaRules?.first?.delta == 0.05)
}

private func discoveryJSON(_ value: String) -> Data {
    Data(value.utf8)
}

private let discoveryArtifact =
    #"{"path":"/tmp/Result.xcevalresult","artifactID":"artifact-1","byteDigest":"sha256:bytes","evaluationID":"Search","resultID":"RESULT-1"}"#

private let discoveryXcode =
    #"{"applicationPath":"/Applications/Xcode.app","developerDirectory":"/Applications/Xcode.app/Contents/Developer","version":"27.0","build":"17A1","frameworks":[{"platform":"macOS","path":"/Xcode/Evaluations.framework"}],"exportsEvaluations":true,"exportSchemaVersion":"1.0"}"#
