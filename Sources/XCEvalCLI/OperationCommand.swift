import ArgumentParser
import XCEvalCore

struct OperationCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "operation",
        abstract: "Read one durable evaluation operation receipt."
    )

    @Argument(help: "Caller-stable operation ID.")
    var id: String

    @Option(
        name: .long,
        help: "Directory containing durable operation receipts."
    )
    var stateDirectory = ".xceval/operations"

    @OptionGroup var outputOptions: StandardOutputOptions

    mutating func run() throws {
        let output = try outputOptions.resolve()
        let receipt = try OperationReceiptStore(
            directory: expandedURL(stateDirectory)
        ).load(idempotencyKey: id)

        switch output.format {
        case .text:
            print("Operation: \(receipt.idempotencyKey)")
            print("Attempt: \(receipt.attempt)")
            print("State: \(receipt.state.rawValue)")
            print("Started: \(receipt.startedAt.formatted(.iso8601))")
            if let endedAt = receipt.endedAt {
                print("Ended: \(endedAt.formatted(.iso8601))")
            }
            if let process = receipt.process {
                print("Exit status: \(process.status)")
                print("Termination: \(process.terminationReason.rawValue)")
                if let path = process.standardOutputLog {
                    print("Standard output log: \(path)")
                }
                if let path = process.standardErrorLog {
                    print("Standard error log: \(path)")
                }
            }
            for artifact in receipt.outputs {
                print("Output: \(artifact.path)")
            }
            if let errorMessage = receipt.errorMessage {
                print("Error: \(errorMessage)")
            }
        case .json:
            try CLIOutput.emit(receipt, options: output)
        case .jsonl, .rawJSON:
            preconditionFailure("Validated output format is exhaustive.")
        }
    }
}
