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
            emits stable machine-readable output for scripts, CI, and developer \
            tools.
            """,
        version: "0.2.1",
        subcommands: [
            InitCommand.self,
            CapabilitiesCommand.self,
            DoctorCommand.self,
            ListCommand.self,
            ValidateCommand.self,
            InspectCommand.self,
            SamplesCommand.self,
            MetricsCommand.self,
            ReportCommand.self,
            DatasetCommand.self,
            CompareCommand.self,
            GateCommand.self,
            ConvertCommand.self,
            PipelineCommand.self,
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
              xceval init SearchQuality
              xceval capabilities
              xceval doctor
              xceval inspect Result.xcevalresult
              xceval report Result.xcevalresult --output json
              xceval samples Result.xcevalresult --output jsonl
              xceval gate Result.xcevalresult --rule 'Mean of Accuracy>=0.9'
              xceval pipeline
              xceval test -- -project App.xcodeproj -scheme App test
              xceval export Tests.xcresult
            """
        )
    }
}
