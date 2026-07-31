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
        throws: XCEvalFormatError.unsupportedCommand("metrics")
    ) {
        try XCEvalDocumentDecoder.decode(
            Data(
                """
                {"schemaVersion":"xceval/v1","command":"metrics"}
                """.utf8
            )
        )
    }
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
