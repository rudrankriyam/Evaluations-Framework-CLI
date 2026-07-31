import Foundation
import Testing
import XCEvalFormat

@Test("Golden inspect output decodes through the public format product")
func decodesInspectFixture() throws {
    let document = try XCEvalDocumentDecoder.decode(
        fixture(named: "inspect.json")
    )
    guard case .inspect(let inspect) = document else {
        Issue.record("Expected an inspect document.")
        return
    }

    #expect(inspect.schemaVersion == "xceval/v1")
    #expect(inspect.artifact.evaluationID == "BookSearch")
    #expect(inspect.artifact.resultID == "RESULT-1")
    #expect(inspect.artifact.sampleCount == 1)
    #expect(
        inspect.artifact.samples?.first?.input?["record"]?["id"]?
            .stringValue == "book-1"
    )
    #expect(inspect.artifact.samples?.first?.metrics.first?.value == .integer(5))
}

@Test("Golden samples output validates its declared sample count")
func decodesSamplesFixture() throws {
    let document = try XCEvalDocumentDecoder.decode(
        fixture(named: "samples.json")
    )
    guard case .samples(let samples) = document else {
        Issue.record("Expected a samples document.")
        return
    }

    #expect(samples.sampleCount == samples.samples.count)
    #expect(samples.samples.first?.metrics.first?.name == "Relevance")
}

@Test("Golden JSON Lines output decodes every normalized sample")
func decodesSamplesJSONLinesFixture() throws {
    let lines = try XCEvalDocumentDecoder.decodeJSONLines(
        fixture(named: "samples.jsonl")
    )

    #expect(lines.count == 1)
    #expect(lines.first?.evaluationID == "BookSearch")
    #expect(lines.first?.resultID == "RESULT-1")
    #expect(lines.first?.sample.index == 0)
}

@Test(
    "Empty JSON Lines output decodes as an empty sample list",
    arguments: [Data(), Data(" \t\r\n".utf8)]
)
func decodesEmptySamplesJSONLines(data: Data) throws {
    let lines = try XCEvalDocumentDecoder.decodeJSONLines(data)

    #expect(lines.isEmpty)
}

@Test("Decoder rejects unsupported schemas and commands")
func rejectsUnsupportedDocuments() {
    #expect(
        throws: XCEvalFormatError.unsupportedSchema("xceval/v2")
    ) {
        try XCEvalDocumentDecoder.decode(
            Data(
                """
                {"schemaVersion":"xceval/v2","command":"samples"}
                """.utf8
            )
        )
    }
    #expect(
        throws: XCEvalFormatError.unsupportedCommand("unknown")
    ) {
        try XCEvalDocumentDecoder.decode(
            Data(
                """
                {"schemaVersion":"xceval/v1","command":"unknown"}
                """.utf8
            )
        )
    }
}

@Test("Public decoder supports artifact discovery and analysis documents")
func decodesArtifactAnalysisDocuments() throws {
    let list = try XCEvalDocumentDecoder.decode(
        json(
            """
            {
              "schemaVersion":"xceval/v1",
              "command":"list",
              "count":1,
              "artifacts":[\(artifactListItem)]
            }
            """
        )
    )
    guard case .list(let listDocument) = list else {
        Issue.record("Expected a list document.")
        return
    }
    #expect(listDocument.count == 1)
    #expect(listDocument.artifacts.first?.resultID == "RESULT-1")

    let validate = try XCEvalDocumentDecoder.decode(
        json(
            """
            {
              "schemaVersion":"xceval/v1",
              "command":"validate",
              "valid":false,
              "errorCount":1,
              "warningCount":0,
              "artifacts":[{
                "artifact":\(artifactIdentity),
                "valid":false,
                "errorCount":1,
                "warningCount":0,
                "issues":[{
                  "severity":"error",
                  "code":"negative_duration",
                  "message":"durationInMilliseconds must not be negative."
                }]
              }]
            }
            """
        )
    )
    guard case .validate(let validationDocument) = validate else {
        Issue.record("Expected a validation document.")
        return
    }
    #expect(validationDocument.valid == false)
    #expect(validationDocument.artifacts.first?.issues.first?.severity == .error)

    let metrics = try XCEvalDocumentDecoder.decode(
        json(
            """
            {
              "schemaVersion":"xceval/v1",
              "command":"metrics",
              "artifact":\(artifactIdentity),
              "profiles":[\(metricProfile)],
              "summary":[\(summaryMetric)]
            }
            """
        )
    )
    guard case .metrics(let metricsDocument) = metrics else {
        Issue.record("Expected a metrics document.")
        return
    }
    #expect(metricsDocument.profiles.first?.mean == 0.75)
    #expect(metricsDocument.summary.first?.name == "Mean of Accuracy")
}

@Test("Public decoder supports reports, datasets, comparisons, and gates")
func decodesDerivedAnalysisDocuments() throws {
    let report = try XCEvalDocumentDecoder.decode(
        json(
            """
            {
              "schemaVersion":"xceval/v1",
              "command":"report",
              "artifact":\(artifactDocument),
              "profiles":[\(metricProfile)],
              "samples":[{
                "sample":\(sample),
                "failedMetrics":["Accuracy"],
                "issues":[{
                  "path":"$.answer",
                  "kind":"value-mismatch",
                  "message":"Subject and expected values do not match.",
                  "subject":"no",
                  "expected":"yes"
                }]
              }],
              "aggregateComparison":[\(metricComparison)]
            }
            """
        )
    )
    guard case .report(let reportDocument) = report else {
        Issue.record("Expected a report document.")
        return
    }
    #expect(reportDocument.samples.first?.failedMetrics == ["Accuracy"])
    #expect(reportDocument.samples.first?.issues.first?.kind == .valueMismatch)

    let dataset = try XCEvalDocumentDecoder.decode(
        json(
            """
            {
              "schemaVersion":"xceval/v1",
              "command":"dataset",
              "artifact":\(artifactIdentity),
              "rowCount":1,
              "pairCount":1,
              "records":[\(datasetRecord)]
            }
            """
        )
    )
    guard case .dataset(let datasetDocument) = dataset else {
        Issue.record("Expected a dataset document.")
        return
    }
    #expect(datasetDocument.records.first?.prompt == "Hello")
    #expect(datasetDocument.records.first?.response == .string("Hi"))

    let compare = try XCEvalDocumentDecoder.decode(
        json(
            """
            {
              "schemaVersion":"xceval/v1",
              "command":"compare",
              "baseline":\(artifactIdentity),
              "candidate":\(artifactIdentity),
              "metrics":[\(metricComparison)],
              "sampleKeyStrategy":{"canonicalInputDigest":{}},
              "samples":[]
            }
            """
        )
    )
    guard case .compare(let compareDocument) = compare else {
        Issue.record("Expected a compare document.")
        return
    }
    #expect(compareDocument.metrics.first?.delta == 0.25)
    #expect(compareDocument.sampleKeyStrategy == .canonicalInputDigest)
    #expect(compareDocument.samples?.isEmpty == true)

    let gate = try XCEvalDocumentDecoder.decode(
        json(
            """
            {
              "schemaVersion":"xceval/v1",
              "command":"gate",
              "artifact":\(artifactIdentity),
              "passed":true,
              "rules":[{
                "expression":"Mean of Accuracy>=0.9",
                "resolvedMetric":"Mean of Accuracy",
                "actual":0.95,
                "expected":0.9,
                "comparison":">=",
                "passed":true
              }]
            }
            """
        )
    )
    guard case .gate(let gateDocument) = gate else {
        Issue.record("Expected a gate document.")
        return
    }
    #expect(gateDocument.rules.first?.comparison == .greaterThanOrEqual)
}

@Test("Public decoder supports execution and Xcode documents")
func decodesExecutionDocuments() throws {
    let run = try XCEvalDocumentDecoder.decode(
        json(
            """
            {
              "schemaVersion":"xceval/v1",
              "command":"run",
              "producerCommand":["swift","run","Evaluate"],
              "workingDirectory":"/tmp/project",
              "resultsPath":"/tmp/project/results",
              "process":\(processResult),
              "artifacts":[\(artifactListItem)]
            }
            """
        )
    )
    guard case .run(let runDocument) = run else {
        Issue.record("Expected a run document.")
        return
    }
    #expect(runDocument.process.status == 0)
    #expect(runDocument.artifacts.count == 1)

    let test = try XCEvalDocumentDecoder.decode(
        json(
            """
            {
              "schemaVersion":"xceval/v1",
              "command":"test",
              "xcodebuildArguments":["-scheme","Example","test"],
              "resultBundlePath":"/tmp/Tests.xcresult",
              "outputDirectory":"/tmp/evaluations",
              "xcode":\(xcodeInstallation),
              "process":\(processResult),
              "exportedFiles":["/tmp/evaluations/Result.xcevalresult"],
              "manifest":{"version":1}
            }
            """
        )
    )
    guard case .test(let testDocument) = test else {
        Issue.record("Expected a test document.")
        return
    }
    #expect(testDocument.xcode.version == "27.0")
    #expect(testDocument.manifest?["version"] == .integer(1))

    let export = try XCEvalDocumentDecoder.decode(
        json(
            """
            {
              "schemaVersion":"xceval/v1",
              "command":"export",
              "xcresultPath":"/tmp/Tests.xcresult",
              "outputDirectory":"/tmp/evaluations",
              "xcode":\(xcodeInstallation),
              "onlyFailures":false,
              "exportedFiles":["/tmp/evaluations/Result.xcevalresult"]
            }
            """
        )
    )
    guard case .export(let exportDocument) = export else {
        Issue.record("Expected an export document.")
        return
    }
    #expect(exportDocument.onlyFailures == false)
}

@Test("Public decoder preserves existing init and pipeline schema versions")
func decodesAlternateSchemaDocuments() throws {
    let pipeline = try XCEvalDocumentDecoder.decode(
        json(
            """
            {
              "schemaVersion":"xceval.pipeline-report/v1",
              "command":"pipeline",
              "name":"Search Quality",
              "manifestPath":"/tmp/xceval.pipeline.json",
              "workingDirectory":"/tmp/project",
              "resultsPath":"/tmp/project/results",
              "artifactsDirectory":"/tmp/project/.xceval/pipeline",
              "steps":[{
                "name":"evaluate",
                "command":["swift","run","Evaluate"],
                "status":0,
                "standardOutputPath":"/tmp/stdout.log",
                "standardErrorPath":"/tmp/stderr.log"
              }],
              "artifact":\(artifactIdentity),
              "validation":{
                "artifact":\(artifactIdentity),
                "valid":true,
                "errorCount":0,
                "warningCount":0,
                "issues":[]
              },
              "gates":[],
              "aggregateComparison":[],
              "outputs":{"inspect":"/tmp/inspect.json"},
              "passed":true,
              "errors":[]
            }
            """
        )
    )
    guard case .pipeline(let pipelineDocument) = pipeline else {
        Issue.record("Expected a pipeline document.")
        return
    }
    #expect(pipelineDocument.schemaVersion == "xceval.pipeline-report/v1")
    #expect(pipelineDocument.steps.first?.name == "evaluate")

    let initialize = try XCEvalDocumentDecoder.decode(
        json(
            """
            {
              "schemaVersion":"xceval.init/v1",
              "command":"init",
              "name":"Search Quality",
              "packageName":"SearchQualityEvaluations",
              "executableName":"search-quality-evaluate",
              "destination":"/tmp/SearchQualityEvaluations",
              "files":["/tmp/SearchQualityEvaluations/Package.swift"]
            }
            """
        )
    )
    guard case .initialize(let initDocument) = initialize else {
        Issue.record("Expected an init document.")
        return
    }
    #expect(initDocument.schemaVersion == "xceval.init/v1")
    #expect(initDocument.files.count == 1)
}

@Test("Public decoder supports declared evaluation targets")
func decodesTargetDocuments() throws {
    let targets = try XCEvalDocumentDecoder.decode(
        json(
            """
            {
              "schemaVersion":"xceval.targets/v1",
              "command":"targets",
              "manifestPath":"/tmp/.xceval/targets.json",
              "count":1,
              "targets":[\(targetDocument)]
            }
            """
        )
    )
    guard case .targets(let targetsDocument) = targets else {
        Issue.record("Expected a targets document.")
        return
    }
    #expect(targetsDocument.targets.first?.kind == .command)
    #expect(targetsDocument.targets.first?.outputs.first?.minimumCount == 1)

    let target = try XCEvalDocumentDecoder.decode(
        json(
            """
            {
              "schemaVersion":"xceval.targets/v1",
              "command":"target",
              "manifestPath":"/tmp/.xceval/targets.json",
              "target":\(targetDocument)
            }
            """
        )
    )
    guard case .target(let targetDetail) = target else {
        Issue.record("Expected a target document.")
        return
    }
    #expect(targetDetail.target.id == "search-quality")
    #expect(targetDetail.target.sampleKeyPointer == "/id")
}

@Test("Public decoder supports remaining normalized command documents")
func decodesRemainingDocuments() throws {
    let convert = try XCEvalDocumentDecoder.decode(
        json(
            """
            {
              "schemaVersion":"xceval/v1",
              "command":"convert",
              "inputPath":"results",
              "format":"jsonl",
              "artifactCount":1,
              "outputPath":"results.jsonl",
              "writtenFiles":["results.jsonl"]
            }
            """
        )
    )
    guard case .convert(let convertDocument) = convert else {
        Issue.record("Expected a convert document.")
        return
    }
    #expect(convertDocument.format == "jsonl")

    let doctor = try XCEvalDocumentDecoder.decode(
        json(
            """
            {
              "schemaVersion":"xceval/v1",
              "command":"doctor",
              "artifactInspectionAvailable":true,
              "evaluationExportAvailable":true,
              "selectedXcode":\(xcodeInstallation),
              "discoveredXcodes":[\(xcodeInstallation)],
              "operatingSystem":"macOS"
            }
            """
        )
    )
    guard case .doctor(let doctorDocument) = doctor else {
        Issue.record("Expected a doctor document.")
        return
    }
    #expect(doctorDocument.evaluationExportAvailable)

    let capabilities = try XCEvalDocumentDecoder.decode(
        json(
            """
            {
              "schemaVersion":"xceval/v1",
              "command":"capabilities",
              "productName":"xceval",
              "naming":"Community-defined name.",
              "affiliation":"Unofficial.",
              "capabilities":[{
                "name":"Inspect results",
                "frameworkAPIs":["EvaluationResult"],
                "support":"native",
                "command":"xceval inspect",
                "boundary":"Persisted results only.",
                "automationUse":"Read normalized output."
              }]
            }
            """
        )
    )
    guard case .capabilities(let capabilitiesDocument) = capabilities else {
        Issue.record("Expected a capabilities document.")
        return
    }
    #expect(capabilitiesDocument.capabilities.first?.support == .native)
}

@Test("Dataset JSON Lines decode through a dedicated public entry point")
func decodesDatasetJSONLines() throws {
    let lines = try XCEvalDocumentDecoder.decodeDatasetJSONLines(
        json(
            #"{"schemaVersion":"xceval/v1","evaluationID":"BookSearch","resultID":"RESULT-1","record":\#(datasetRecord)}"#
                + "\n"
        )
    )

    #expect(lines.count == 1)
    #expect(lines.first?.record.sampleIndex == 0)
    #expect(lines.first?.record.input?["id"] == .string("sample-1"))
}

@Test("Direct document decoding rejects mismatched sample counts")
func rejectsMismatchedSampleCount() {
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(
            XCEvalSamplesDocument.self,
            from: Data(
                """
                {
                  "schemaVersion": "xceval/v1",
                  "command": "samples",
                  "path": "Result.xcevalresult",
                  "sampleCount": 1,
                  "samples": []
                }
                """.utf8
            )
        )
    }
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(
            XCEvalInspectDocument.self,
            from: Data(
                """
                {
                  "schemaVersion": "xceval/v1",
                  "command": "inspect",
                  "artifact": {
                    "path": "Result.xcevalresult",
                    "sampleCount": 1,
                    "info": {},
                    "reportMetadata": {},
                    "otherFields": {},
                    "summary": [],
                    "samples": []
                  }
                }
                """.utf8
            )
        )
    }
}

private func fixture(named name: String) throws -> Data {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try Data(
        contentsOf:
            packageRoot
            .appendingPathComponent("Contracts/xceval-v1")
            .appendingPathComponent(name)
    )
}

private func json(_ string: String) -> Data {
    Data(string.utf8)
}

private let artifactIdentity =
    #"{"path":"/tmp/Result.xcevalresult","evaluationID":"BookSearch","resultID":"RESULT-1"}"#

private let artifactListItem =
    #"{"path":"/tmp/Result.xcevalresult","evaluationID":"BookSearch","resultID":"RESULT-1","sampleCount":1,"summaryMetricCount":1,"startTime":"2026-07-31T00:00:00Z","durationInMilliseconds":12}"#

private let summaryMetric =
    #"{"name":"Mean of Accuracy","group":"Quality","operationType":"mean","sourceMetric":"Accuracy","value":0.75,"details":{"value":0.75}}"#

private let metricProfile =
    #"{"name":"Accuracy","evaluatorKinds":["custom"],"sampleCount":1,"passCount":1,"failCount":0,"scoreCount":0,"ignoredCount":0,"rationaleCount":0,"numericCount":1,"minimum":0.75,"maximum":0.75,"mean":0.75,"median":0.75,"variance":0,"standardDeviation":0,"numericValues":[0.75]}"#

private let sample =
    #"{"index":0,"input":{"id":"sample-1","prompt":"Hello"},"response":{"value":"Hi"},"expected":"Hi","metrics":[],"otherColumns":{}}"#

private let artifactDocument =
    #"{"path":"/tmp/Result.xcevalresult","evaluationID":"BookSearch","resultID":"RESULT-1","startTime":"2026-07-31T00:00:00Z","endTime":"2026-07-31T00:00:01Z","durationInMilliseconds":12,"sampleCount":1,"info":{},"reportMetadata":{},"otherFields":{},"summary":[]}"#

private let datasetRecord =
    #"{"sampleIndex":0,"prompt":"Hello","response":"Hi","expected":"Hi","input":{"id":"sample-1"}}"#

private let metricComparison =
    #"{"name":"Mean of Accuracy","group":"Quality","operationType":"mean","sourceMetric":"Accuracy","occurrence":1,"baseline":0.5,"candidate":0.75,"delta":0.25,"relativeDelta":0.5}"#

private let processResult =
    #"{"status":0,"standardOutput":"ok\n","standardError":""}"#

private let xcodeInstallation =
    #"{"applicationPath":"/Applications/Xcode.app","developerDirectory":"/Applications/Xcode.app/Contents/Developer","version":"27.0","build":"17A1","frameworks":[{"platform":"macOS","path":"/Applications/Xcode.app/Evaluations.framework"}],"exportsEvaluations":true,"exportSchemaVersion":"1.0"}"#

private let targetDocument =
    #"{"id":"search-quality","kind":"command","revision":"sha256:abc","workingDirectory":".","argv":["swift","run","Evaluate"],"environment":{"inherit":["MODEL_API_KEY"],"set":{}},"outputs":[{"role":"evaluation-results","path":"results","format":"xcevalresult","minimumCount":1}],"requirements":[{"capability":"apple.evaluations","minimumVersion":"27"}],"sampleKeyPointer":"/id"}"#
