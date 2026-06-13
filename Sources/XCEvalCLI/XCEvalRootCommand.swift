import ArgumentParser
import XCEvalCore

@main
struct XCEvalRootCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xceval",
        abstract: "Run and inspect Apple Evaluations workflows from the command line.",
        discussion: """
            xceval is an unofficial community tool, not an Apple command or \
            product. It orchestrates typed evaluation producers, reads \
            .xcevalresult JSON, exports attachments from .xcresult bundles, and \
            emits stable machine-readable output for agents and automation.
            """,
        version: "0.2.0",
        subcommands: [
            CapabilitiesCommand.self,
            DoctorCommand.self,
            ListCommand.self,
            ValidateCommand.self,
            InspectCommand.self,
            SamplesCommand.self,
            MetricsCommand.self,
            DatasetCommand.self,
            CompareCommand.self,
            GateCommand.self,
            ConvertCommand.self,
            RunCommand.self,
            TestCommand.self,
            ExportCommand.self,
            SchemaCommand.self
        ]
    )

    mutating func run() async throws {
        print(
            """
            xceval is an unofficial CLI for Apple Evaluations workflows.

            Start with:
              xceval capabilities
              xceval doctor
              xceval inspect Result.xcevalresult
              xceval samples Result.xcevalresult --output jsonl
              xceval gate Result.xcevalresult --rule 'Mean of Accuracy>=0.9'
              xceval test -- -project App.xcodeproj -scheme App test
              xceval export Tests.xcresult
            """
        )
    }
}
