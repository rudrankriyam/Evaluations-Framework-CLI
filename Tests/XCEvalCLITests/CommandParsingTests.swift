import Testing

@testable import XCEvalCLI

@Test("Subcommands own their output options")
func subcommandsOwnOutputOptions() throws {
    let command = try XCEvalRootCommand.parseAsRoot([
        "samples",
        "Result.xcevalresult",
        "--output",
        "jsonl"
    ])
    let samples = try #require(command as? SamplesCommand)

    #expect(samples.path == "Result.xcevalresult")
    #expect(samples.outputOptions.output == .jsonl)
}
