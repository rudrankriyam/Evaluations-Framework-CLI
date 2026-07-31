import ArgumentParser
import Darwin
import Foundation
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
        version: "0.4.0",
        subcommands: [
            InitCommand.self,
            PlanCommand.self,
            ApiCommand.self,
            CapabilitiesCommand.self,
            DoctorCommand.self,
            TargetsCommand.self,
            TargetCommand.self,
            OperationCommand.self,
            SelectCommand.self,
            DatasetsCommand.self,
            ListCommand.self,
            ValidateCommand.self,
            InspectCommand.self,
            SamplesCommand.self,
            MetricsCommand.self,
            ReportCommand.self,
            EvidenceCommand.self,
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

    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        do {
            var command = try await asyncParseAsRoot(arguments)
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch let exitCode as ExitCode {
            exit(withError: exitCode)
        } catch let cleanExit as CleanExit {
            exit(withError: cleanExit)
        } catch {
            if shouldEmitMachineJSON(arguments) {
                let document = machineErrorDocument(
                    error: error,
                    arguments: arguments
                )
                FileHandle.standardError.write(
                    Data("Error: \(userFacingErrorMessage(error))\n".utf8)
                )
                try? CLIOutput.emit(
                    document,
                    options: ResolvedOutputOptions(
                        format: .json,
                        pretty: arguments.contains("--pretty")
                    )
                )
                Darwin.exit(1)
            }
            exit(withError: error)
        }
    }

    mutating func run() async throws {
        print(
            """
            xceval is an unofficial CLI for Apple Evaluations workflows.

            Start with:
              xceval init SearchQuality --template deterministic
              xceval api verify
              xceval targets --output json
              xceval run TARGET --operation-id RUN_ID --output json
              xceval evidence Result.xcevalresult --output json
              xceval plan --run-id RUN_ID
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

func shouldEmitMachineJSON(
    _ arguments: [String],
    stdoutIsTerminal: Bool = isatty(fileno(stdout)) == 1
) -> Bool {
    let optionArguments = Array(arguments.prefix { $0 != "--" })
    let requestsArgumentParserOutput =
        optionArguments.first == "help"
        || optionArguments.contains("--help")
        || optionArguments.contains("-h")
        || optionArguments.contains("--version")
        || optionArguments.contains("--experimental-dump-help")
        || optionArguments.contains("--generate-completion-script")
    if requestsArgumentParserOutput {
        return false
    }
    var explicitOutput: String?
    for index in optionArguments.indices {
        if optionArguments[index] == "--output",
            optionArguments.indices.contains(index + 1)
        {
            explicitOutput = optionArguments[index + 1]
        } else if optionArguments[index].hasPrefix("--output=") {
            explicitOutput = String(
                optionArguments[index].dropFirst("--output=".count)
            )
        }
    }
    if let explicitOutput {
        return explicitOutput == "json"
    }
    return !stdoutIsTerminal
}
