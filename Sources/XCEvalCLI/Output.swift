import ArgumentParser
import Darwin
import Foundation

enum CLIOutputFormat {
    case text
    case json
    case jsonl
    case rawJSON
}

enum StandardOutputFormat: String, CaseIterable, ExpressibleByArgument {
    case text
    case json
}

enum InspectOutputFormat: String, CaseIterable, ExpressibleByArgument {
    case text
    case json
    case rawJSON = "raw-json"
}

enum SamplesOutputFormat: String, CaseIterable, ExpressibleByArgument {
    case text
    case json
    case jsonl
}

struct StandardOutputOptions: ParsableArguments {
    @Option(
        name: .long,
        help: "Output format. Defaults to text in a terminal and JSON when piped."
    )
    var output: StandardOutputFormat?

    @Flag(
        name: .long,
        help: "Pretty-print JSON output."
    )
    var pretty = false

    func resolve() throws -> ResolvedOutputOptions {
        let format = output ?? (isatty(fileno(stdout)) == 1 ? .text : .json)
        if pretty, format != .json {
            throw ValidationError("--pretty is only valid with JSON output.")
        }
        return ResolvedOutputOptions(
            format: format == .text ? .text : .json,
            pretty: pretty
        )
    }
}

struct InspectOutputOptions: ParsableArguments {
    @Option(
        name: .long,
        help: "Output format. Defaults to text in a terminal and JSON when piped."
    )
    var output: InspectOutputFormat?

    @Flag(
        name: .long,
        help: "Pretty-print JSON output."
    )
    var pretty = false

    func resolve() throws -> ResolvedOutputOptions {
        let format = output ?? (isatty(fileno(stdout)) == 1 ? .text : .json)
        if pretty, format != .json {
            throw ValidationError("--pretty is only valid with JSON output.")
        }
        let resolved: CLIOutputFormat
        switch format {
        case .text:
            resolved = .text
        case .json:
            resolved = .json
        case .rawJSON:
            resolved = .rawJSON
        }
        return ResolvedOutputOptions(format: resolved, pretty: pretty)
    }
}

struct SamplesOutputOptions: ParsableArguments {
    @Option(
        name: .long,
        help: "Output format. Defaults to text in a terminal and JSON when piped."
    )
    var output: SamplesOutputFormat?

    @Flag(
        name: .long,
        help: "Pretty-print JSON output."
    )
    var pretty = false

    func resolve() throws -> ResolvedOutputOptions {
        let format = output ?? (isatty(fileno(stdout)) == 1 ? .text : .json)
        if pretty, format != .json {
            throw ValidationError("--pretty is only valid with JSON output.")
        }
        let resolved: CLIOutputFormat
        switch format {
        case .text:
            resolved = .text
        case .json:
            resolved = .json
        case .jsonl:
            resolved = .jsonl
        }
        return ResolvedOutputOptions(format: resolved, pretty: pretty)
    }
}

struct ResolvedOutputOptions {
    let format: CLIOutputFormat
    let pretty: Bool
}

enum CLIOutput {
    static func emit<T: Encodable>(
        _ value: T,
        options: ResolvedOutputOptions
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if options.pretty {
            encoder.outputFormatting.insert(.prettyPrinted)
        }
        let data = try encoder.encode(value)
        write(data)
    }

    static func emitJSONLines<T: Encodable>(_ values: [T]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for value in values {
            write(try encoder.encode(value))
        }
    }

    static func emitRaw(_ data: Data) {
        FileHandle.standardOutput.write(data)
    }

    private static func write(_ data: Data) {
        FileHandle.standardOutput.write(data)
        if data.last != 0x0A {
            FileHandle.standardOutput.write(Data([0x0A]))
        }
    }
}

func expandedURL(_ path: String) -> URL {
    URL(
        fileURLWithPath: (path as NSString).expandingTildeInPath
    ).standardizedFileURL
}

func formattedNumber(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0...6)))
}
