import EvaluationsLabSupport
import Foundation

@main
struct EvaluationsLabCLI {
    static func main() async {
        do {
            let outputDirectory: URL
            if let configuredPath = ProcessInfo.processInfo.environment[
                "EVALUATIONS_LAB_OUTPUT_DIR"
            ] {
                outputDirectory = URL(filePath: configuredPath, directoryHint: .isDirectory)
            } else {
                outputDirectory = FileManager.default.temporaryDirectory
                    .appending(
                        path: "EvaluationsLab-\(UUID().uuidString)",
                        directoryHint: .isDirectory
                    )
            }

            let summary = try await OfflineHarness.run(in: outputDirectory)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(summary)
            print(String(decoding: data, as: UTF8.self))
        } catch {
            FileHandle.standardError.write(
                Data("EvaluationsLabCLI failed: \(error)\n".utf8)
            )
            Foundation.exit(EXIT_FAILURE)
        }
    }
}
