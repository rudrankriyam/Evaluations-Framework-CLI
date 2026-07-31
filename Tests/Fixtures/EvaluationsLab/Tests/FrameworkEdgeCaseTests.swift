import Evaluations
import EvaluationsLabSupport
import Foundation
import FoundationModels
import Testing

private enum EdgeCaseFixtureError: Error, Equatable {
    case streamFailed
}

private struct CustomModelSample: ModelSampleProtocol, Codable {
    let input: ModelSampleInput
    let output: ModelSampleOutput<String, TrajectoryExpectation>

    var expected: String? {
        output.value
    }
}

private struct SingleSampleVarianceEvaluation: Evaluation {
    let sampleValue = Metric("single_sample_value")
    let dataset = ArrayLoader(samples: [
        ModelSample(prompt: "one", expected: "ONE")
    ])

    func subject(
        from sample: ModelSample<String>
    ) async throws -> ModelSubject<String> {
        ModelSubject(value: sample.promptDescription.uppercased())
    }

    var evaluators: Evaluators {
        Evaluator { _, _ in
            sampleValue.scoring(1)
        }
    }

    func aggregateMetrics(using aggregator: inout MetricsAggregator) {
        aggregator.computeVariance(of: sampleValue)
        aggregator.computeStandardDeviation(of: sampleValue)
    }
}

@Suite("Beta 4 persistence boundaries")
struct PersistenceEdgeCaseTests {
    @Test("Default JSON data round-trips through the data initializer")
    func defaultJSONDataRoundTrip() async throws {
        let result = try await OfflineFixtures.evaluation.run()
        let data = try result.jsonData()
        let loaded = try EvaluationResult(jsonData: data)

        #expect(loaded.resultID == result.resultID)
        #expect(loaded.evaluationID == result.evaluationID)
        #expect(loaded.detailed.rows.count == result.detailed.rows.count)
    }

    @Test("Metadata-inclusive JSON data round-trips")
    func metadataInclusiveJSONDataRoundTrip() async throws {
        var result = try await OfflineFixtures.evaluation.run()
        result.reportMetadata["lane"] = "metadata-inclusive"

        let data = try result.jsonData(includeReportMetadata: true)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let metadata = try #require(object["reportMetadata"] as? [String: Any])
        #expect(metadata["lane"] as? String == "metadata-inclusive")

        let loaded = try EvaluationResult(jsonData: data)
        #expect(loaded.resultID == result.resultID)
        #expect(loaded.reportMetadata["lane"] as? String == "metadata-inclusive")
    }

    @Test("Metadata-inclusive JSON and JSON Lines files round-trip")
    func metadataInclusiveFileRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "EvaluationsLabMetadata-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        var result = try await OfflineFixtures.evaluation.run()
        result.reportMetadata["lane"] = "metadata-inclusive"

        let jsonURL = try result.saveJSON(
            to: directory,
            includeReportMetadata: true
        )
        let loadedJSON = try EvaluationResult.loadJSON(from: jsonURL)
        #expect(loadedJSON.resultID == result.resultID)
        #expect(
            loadedJSON.reportMetadata["lane"] as? String
                == "metadata-inclusive"
        )

        let jsonLinesURL = directory.appending(
            path: "metadata-results.jsonl",
            directoryHint: .notDirectory
        )
        try [result, result].saveJSONLines(
            to: jsonLinesURL,
            includeReportMetadata: true
        )
        let loadedLines = try await EvaluationResult.loadJSONLines(
            from: jsonLinesURL
        )
        #expect(loadedLines.count == 2)
        #expect(
            loadedLines.allSatisfy {
                $0.reportMetadata["lane"] as? String == "metadata-inclusive"
            }
        )
    }

    @Test("Single-sample variance prevents JSON persistence")
    func singleSampleVariancePersistenceFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "EvaluationsLabSingleVariance-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let result = try await SingleSampleVarianceEvaluation().run()

        do {
            _ = try result.saveJSON(to: directory)
            Issue.record(
                "Expected Beta 4 to reject the non-finite aggregate value."
            )
        } catch {
            #expect(error is EncodingError)
        }
    }

    @Test("EvaluationResult reports missing, empty, and malformed files")
    func resultFileErrors() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "EvaluationsLabResultErrors-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let missingURL = directory.appending(path: "missing.xcevalresult")
        do {
            _ = try EvaluationResult.loadJSON(from: missingURL)
            Issue.record("Expected a missing result file to fail.")
        } catch {
            #expect(!(error is EvaluationResultsError))
        }

        let emptyURL = directory.appending(path: "empty.xcevalresult")
        try Data().write(to: emptyURL)
        do {
            _ = try EvaluationResult.loadJSON(from: emptyURL)
            Issue.record("Expected an empty result file to fail.")
        } catch {
            #expect(!(error is EvaluationResultsError))
        }

        let malformedURL = directory.appending(path: "malformed.xcevalresult")
        try Data(#"{"evaluationID":"broken""#.utf8).write(to: malformedURL)
        do {
            _ = try EvaluationResult.loadJSON(from: malformedURL)
            Issue.record("Expected a malformed result file to fail.")
        } catch {
            #expect(!(error is EvaluationResultsError))
        }
    }
}

@Suite("Loader failure behavior")
struct LoaderEdgeCaseTests {
    @Test("Beta 4 silently drops the entire array after one malformed entry")
    func malformedJSONEntry() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "EvaluationsLabMalformedLoader-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let url = directory.appending(path: "samples.json")
        let json = """
            [
              {"input":"alpha","expected":"ALPHA","identifier":"first"},
              {"input":42,"expected":"INVALID","identifier":"malformed"},
              {"input":"beta","expected":"BETA","identifier":"second"}
            ]
            """
        try Data(json.utf8).write(to: url)

        let samples = try await OfflineFixtures.collect(
            JSONLoader<TextSample>(url: url)
        )
        #expect(samples.isEmpty)
    }

    @Test("JSONLoader reports a missing file")
    func missingJSONFile() async {
        let missingURL = FileManager.default.temporaryDirectory.appending(
            path: "EvaluationsLabMissing-\(UUID().uuidString).json"
        )

        do {
            _ = try await OfflineFixtures.collect(
                JSONLoader<TextSample>(url: missingURL)
            )
            Issue.record("Expected JSONLoader to reject a missing file.")
        } catch {
            let error = error as NSError
            #expect(error.domain == NSCocoaErrorDomain)
            #expect(error.code == NSFileNoSuchFileError)
        }
    }

    @Test("Beta 4 silently returns no samples for malformed top-level JSON")
    func malformedJSONFile() async throws {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "EvaluationsLabMalformed-\(UUID().uuidString).json"
        )
        try Data(#"[{"input":"unterminated"}"#.utf8).write(to: url)
        defer {
            try? FileManager.default.removeItem(at: url)
        }

        let samples = try await OfflineFixtures.collect(
            JSONLoader<TextSample>(url: url)
        )
        #expect(samples.isEmpty)
    }

    @Test("StreamLoader propagates its source error")
    func streamError() async {
        let stream = AsyncThrowingStream<TextSample, Error> { continuation in
            continuation.yield(OfflineFixtures.samples[0])
            continuation.finish(throwing: EdgeCaseFixtureError.streamFailed)
        }

        do {
            _ = try await OfflineFixtures.collect(StreamLoader(stream: stream))
            Issue.record("Expected StreamLoader to propagate its source error.")
        } catch {
            #expect(error as? EdgeCaseFixtureError == .streamFailed)
        }
    }
}

@Suite("Tool trajectory failures")
struct ToolTrajectoryEdgeCaseTests {
    private let allPass = Metric("edge_tools_all_pass")
    private let percentagePass = Metric("edge_tools_percentage_pass")

    @Test("Missing, wrong-name, and wrong-argument calls fail")
    func basicFailures() async throws {
        let expectation = TrajectoryExpectation(
            expected: "fetch_weather",
            arguments: [
                .exact(argumentName: "city", value: "Cupertino")
            ]
        )

        let missing = try await metrics(
            expectation: expectation,
            calls: []
        )
        assertFailure(missing)

        let wrongName = try await metrics(
            expectation: expectation,
            calls: [("fetch_alerts", #"{"city":"Cupertino"}"#)]
        )
        assertFailure(wrongName)

        let wrongArguments = try await metrics(
            expectation: expectation,
            calls: [("fetch_weather", #"{"city":"Paris"}"#)]
        )
        assertFailure(wrongArguments)
    }

    @Test("Ordered calls fail out of order")
    func orderedFailure() async throws {
        let expectation = TrajectoryExpectation(
            ordered: [
                ToolExpectation("authenticate"),
                ToolExpectation("fetch_weather"),
                ToolExpectation("present_results")
            ],
            allowsAdditionalToolCalls: false
        )
        let metrics = try await metrics(
            expectation: expectation,
            calls: [
                ("fetch_weather", "{}"),
                ("authenticate", "{}"),
                ("present_results", "{}")
            ]
        )

        assertFailure(metrics)
    }

    @Test("Unordered and any-order groups accept reversed calls")
    func unorderedAndAnyOrderSuccess() async throws {
        let unordered = TrajectoryExpectation(
            unordered: [
                ToolExpectation("fetch_weather"),
                ToolExpectation("fetch_alerts")
            ]
        )
        let unorderedMetrics = try await metrics(
            expectation: unordered,
            calls: [
                ("fetch_alerts", "{}"),
                ("fetch_weather", "{}")
            ]
        )
        assertSuccess(unorderedMetrics)

        let anyOrder = TrajectoryExpectation(
            ordered: [
                ToolExpectation("authenticate"),
                .anyOrder([
                    ToolExpectation("fetch_weather"),
                    ToolExpectation("fetch_alerts")
                ]),
                ToolExpectation("present_results")
            ],
            allowsAdditionalToolCalls: false
        )
        let anyOrderMetrics = try await metrics(
            expectation: anyOrder,
            calls: [
                ("authenticate", "{}"),
                ("fetch_alerts", "{}"),
                ("fetch_weather", "{}"),
                ("present_results", "{}")
            ]
        )
        assertSuccess(anyOrderMetrics)
    }

    @Test("Forbidden calls fail")
    func forbiddenCall() async throws {
        let expectation = TrajectoryExpectation(
            ordered: [ToolExpectation("fetch_weather")],
            unordered: [],
            disallowed: [ToolExpectation("delete_location")]
        )
        let metrics = try await metrics(
            expectation: expectation,
            calls: [
                ("fetch_weather", "{}"),
                ("delete_location", "{}")
            ]
        )

        assertFailure(metrics)
    }

    @Test("Additional and duplicate calls follow the explicit policy")
    func additionalAndDuplicateCalls() async throws {
        let allowsAdditional = TrajectoryExpectation(
            ordered: [ToolExpectation("fetch_weather")],
            allowsAdditionalToolCalls: true
        )
        let rejectsAdditional = TrajectoryExpectation(
            ordered: [ToolExpectation("fetch_weather")],
            allowsAdditionalToolCalls: false
        )
        let calls = [
            ("fetch_weather", "{}"),
            ("fetch_weather", "{}")
        ]

        assertSuccess(
            try await metrics(expectation: allowsAdditional, calls: calls)
        )
        assertFailure(
            try await metrics(expectation: rejectsAdditional, calls: calls)
        )
    }

    private func metrics(
        expectation: TrajectoryExpectation,
        calls: [(String, String)]
    ) async throws -> [Metric] {
        let toolCalls = try calls.enumerated().map { index, call in
            Transcript.ToolCall(
                id: "edge-call-\(index)",
                toolName: call.0,
                arguments: try GeneratedContent(json: call.1)
            )
        }
        let transcript = StructuredTranscript(toolCalls: toolCalls)
        let sample = ModelSample<String>(
            prompt: "Exercise the requested tools.",
            expectations: expectation
        )
        let subject = ModelSubject(value: "done", transcript: transcript)
        let evaluator = ToolCallEvaluator<ModelSample<String>>(
            allPass: allPass,
            percentagePass: percentagePass
        )

        return try await evaluator.metrics(subject: subject, input: sample)
    }

    private func assertSuccess(
        _ metrics: [Metric],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(
            metrics[allPass]?.value == .passing,
            sourceLocation: sourceLocation
        )
        #expect(
            metrics[percentagePass]?.doubleValue == 1,
            sourceLocation: sourceLocation
        )
    }

    private func assertFailure(
        _ metrics: [Metric],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(
            metrics[allPass]?.value == .failing,
            sourceLocation: sourceLocation
        )
        #expect(
            metrics[percentagePass]?.doubleValue != 1,
            sourceLocation: sourceLocation
        )
    }
}

@Suite("Value and typed model surfaces")
struct ValueAndTypedSurfaceTests {
    @Test("ArgumentValue covers literals, Codable, and GeneratedContent")
    func argumentValues() throws {
        let values: [ArgumentValue] = [
            "Cupertino",
            3,
            2.5,
            true
        ]
        let decoded = try JSONDecoder().decode(
            [ArgumentValue].self,
            from: JSONEncoder().encode(values)
        )

        #expect(decoded == values)
        #expect(
            decoded.map(\.structuredValue) == [
                .string("Cupertino"),
                .int(3),
                .double(2.5),
                .bool(true)
            ])
        for value in values {
            #expect(try ArgumentValue(value.generatedContent) == value)
        }
    }

    @Test("StructuredValue covers every case and nested Codable values")
    func structuredValues() throws {
        let value: StructuredValue = [
            "string": "Cupertino",
            "integer": 3,
            "double": 2.5,
            "boolean": true,
            "null": .null,
            "array": ["weather", 7, false],
            "dictionary": ["nested": "value"]
        ]
        let decoded = try JSONDecoder().decode(
            StructuredValue.self,
            from: JSONEncoder().encode(value)
        )

        #expect(decoded == value)
        guard case .dictionary(let dictionary) = decoded else {
            Issue.record("Expected a StructuredValue dictionary.")
            return
        }
        #expect(dictionary["null"] == .null)
        #expect(
            dictionary["array"]
                == .array([
                    .string("weather"),
                    .int(7),
                    .bool(false)
                ]))
    }

    @Test("ModelSample input, output, and a custom protocol conformer round-trip")
    func customModelSample() throws {
        let input = ModelSampleInput(
            prompt: Prompt("Use the weather tool."),
            instructions: Instructions("Be concise.")
        )
        let output = ModelSampleOutput<String, TrajectoryExpectation>(
            value: "Sunny",
            expectations: TrajectoryExpectation(expected: "weather")
        )
        let sample = CustomModelSample(input: input, output: output)
        let decoded = try JSONDecoder().decode(
            CustomModelSample.self,
            from: JSONEncoder().encode(sample)
        )

        #expect(decoded.input.promptDescription.contains("weather"))
        #expect(decoded.input.instructionsDescription?.contains("concise") == true)
        #expect(decoded.expected == "Sunny")
        let expectations = try #require(decoded.output.expectations)
        let toolNames =
            expectations.ordered.map(\.name)
            + expectations.unordered.map(\.name)
        #expect(toolNames == ["weather"])

        let standard = ModelSample<String>(
            input: decoded.input,
            expected: decoded.expected,
            expectations: decoded.output.expectations
        )
        #expect(standard.promptDescription == decoded.input.promptDescription)
        #expect(standard.expected == "Sunny")
    }

    @Test("Typed ResultColumn descriptors recover native values")
    func typedResultColumns() async throws {
        let evaluation = OfflineFixtures.evaluation
        let result = try await evaluation.run()
        let inputs = result.detailed[evaluation.inputColumn]
        let responses = result.detailed[evaluation.responseColumn]
        let expected = result.detailed[evaluation.expectedColumn]

        #expect(inputs.count == OfflineFixtures.samples.count)
        #expect(responses.count == OfflineFixtures.samples.count)
        #expect(expected.count == OfflineFixtures.samples.count)
        #expect(try #require(inputs[0]).identifier == "passing")
        #expect(try #require(responses[0]).value == "ALPHA")
        #expect(expected[0] == "ALPHA")
    }

    @Test("EvaluatorsBuilder buildOptional includes and omits its optional lane")
    func conditionalEvaluators() async throws {
        typealias Builder = EvaluatorsBuilder<TextSample, ModelSubject<String>>
        let included = Builder.buildOptional([LengthDeltaEvaluator()])
        let omitted = Builder.buildOptional(nil)

        #expect(included.count == 1)
        #expect(omitted.isEmpty)

        let metrics = try await included[0].metrics(
            subject: ModelSubject(value: "ALPHA"),
            input: OfflineFixtures.samples[0]
        )
        #expect(metrics[HarnessMetric.lengthDelta]?.doubleValue == 0)
    }
}
