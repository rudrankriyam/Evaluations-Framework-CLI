import ArgumentParser
import XCEvalCore

@main
struct XCEvalRootCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xceval",
        abstract: "Inspect Apple Evaluations artifacts without opening Xcode.",
        discussion: """
            xceval reads .xcevalresult JSON, exports evaluation attachments from \
            .xcresult bundles, and emits stable machine-readable output for agents \
            and automation. It does not link or embed Evaluations.framework.
            """,
        version: "0.1.0",
        subcommands: [
            DoctorCommand.self,
            InspectCommand.self,
            SamplesCommand.self,
            CompareCommand.self,
            ExportCommand.self,
            SchemaCommand.self
        ]
    )

    mutating func run() async throws {
        print(
            """
            xceval inspects Apple Evaluations artifacts and Xcode result bundles.

            Start with:
              xceval doctor
              xceval inspect Result.xcevalresult
              xceval samples Result.xcevalresult --output jsonl
              xceval export Tests.xcresult
            """
        )
    }
}
