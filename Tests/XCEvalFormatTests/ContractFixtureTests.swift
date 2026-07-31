import Foundation
import Testing
import XCEvalFormat

@Test(
    "Public decoder accepts every agent protocol contract fixture",
    arguments: [
        "error.json",
        "targets.json",
        "selection.json",
        "operation-receipt.json",
        "evidence.json"
    ]
)
func decodesAgentProtocolFixture(name: String) throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let data = try Data(
        contentsOf:
            packageRoot
            .appendingPathComponent("Contracts/agent-v1")
            .appendingPathComponent(name)
    )

    _ = try XCEvalDocumentDecoder.decode(data)
}
