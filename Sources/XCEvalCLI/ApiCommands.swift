import ArgumentParser
import Darwin
import Foundation
import XCEvalCore

enum AuthoringTemplateOption:
    String,
    CaseIterable,
    ExpressibleByArgument
{
    case deterministic
    case modelJudge = "model-judge"
    case session
    case synthetic
    case toolCall = "tool-call"

    var recipeKind: EvaluationAuthoringRecipeKind {
        switch self {
        case .deterministic:
            .deterministic
        case .modelJudge:
            .modelJudge
        case .session:
            .session
        case .synthetic:
            .synthetic
        case .toolCall:
            .toolCall
        }
    }
}

struct ApiCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "api",
        abstract: "Discover Evaluations APIs and deterministic authoring recipes.",
        subcommands: [
            ApiListCommand.self,
            ApiShowCommand.self,
            ApiExampleCommand.self,
            ApiVerifyCommand.self
        ]
    )
}

struct ApiListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List exact public types from the installed Evaluations interface."
    )

    @Option(
        name: .long,
        help: "Xcode.app or Contents/Developer path. Auto-discovered by default."
    )
    var xcode: String?

    @OptionGroup var outputOptions: StandardOutputOptions

    mutating func run() throws {
        let output = try outputOptions.resolve()
        let catalog = try loadAPICatalog(xcode: xcode)
        let payload = ApiListPayload(catalog: catalog)
        switch output.format {
        case .text:
            printAPIHeader(catalog.source)
            for symbol in payload.symbols {
                print(
                    "\(symbol.kind.rawValue) \(symbol.name) "
                        + "\(symbol.sourceLocation.path):"
                        + "\(symbol.sourceLocation.startLine)"
                )
            }
        case .json:
            try CLIOutput.emit(payload, options: output)
        case .jsonl, .rawJSON:
            preconditionFailure("Validated output format is exhaustive.")
        }
    }
}

struct ApiShowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show one exact public Evaluations type declaration."
    )

    @Argument(help: "Exact type name, optionally qualified with Evaluations.")
    var symbol: String

    @Option(
        name: .long,
        help: "Xcode.app or Contents/Developer path. Auto-discovered by default."
    )
    var xcode: String?

    @OptionGroup var outputOptions: StandardOutputOptions

    mutating func run() throws {
        let output = try outputOptions.resolve()
        let catalog = try loadAPICatalog(xcode: xcode)
        let declaration = try catalog.requireSymbol(named: symbol)
        let payload = ApiShowPayload(
            source: catalog.source,
            symbol: declaration
        )
        switch output.format {
        case .text:
            print(declaration.declaration)
            print()
            print(
                "Source: \(declaration.sourceLocation.path):"
                    + "\(declaration.sourceLocation.startLine)"
            )
        case .json:
            try CLIOutput.emit(payload, options: output)
        case .jsonl, .rawJSON:
            preconditionFailure("Validated output format is exhaustive.")
        }
    }
}

struct ApiExampleCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "example",
        abstract: "Render one deterministic, compile-verified authoring recipe."
    )

    @Argument(help: "Recipe kind.")
    var kind: AuthoringTemplateOption

    @Option(
        name: .long,
        help: "Swift type name to substitute into the rendered source."
    )
    var typeName: String?

    @OptionGroup var outputOptions: StandardOutputOptions

    mutating func run() throws {
        let output = try outputOptions.resolve()
        let recipe = EvaluationAuthoringRecipeCatalog.recipe(
            for: kind.recipeKind
        )
        let resolvedTypeName = typeName ?? recipe.template.defaultTypeName
        let source = try recipe.template.render(typeName: resolvedTypeName)
        let payload = ApiExamplePayload(
            recipe: recipe,
            typeName: resolvedTypeName,
            source: source
        )
        switch output.format {
        case .text:
            print(source)
        case .json:
            try CLIOutput.emit(payload, options: output)
        case .jsonl, .rawJSON:
            preconditionFailure("Validated output format is exhaustive.")
        }
    }
}

struct ApiVerifyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Typecheck authoring recipes against an installed Xcode."
    )

    @Argument(
        help: "Optional recipe kind. Omit to verify every recipe."
    )
    var kind: AuthoringTemplateOption?

    @Option(
        name: .long,
        help: "Xcode.app or Contents/Developer path. Auto-discovered by default."
    )
    var xcode: String?

    @OptionGroup var outputOptions: StandardOutputOptions

    mutating func run() throws {
        let output = try outputOptions.resolve()
        try prepareVerificationEnvironment()
        let installation = try XcodeLocator.evaluationCapableInstallation(
            preferredPath: xcode
        )
        let recipes =
            kind.map {
                [EvaluationAuthoringRecipeCatalog.recipe(for: $0.recipeKind)]
            } ?? EvaluationAuthoringRecipeCatalog.recipes
        let results = try EvaluationAuthoringRecipeVerifier.verifyAll(
            recipes,
            in: installation
        )
        let payload = ApiVerifyPayload(
            xcode: installation,
            results: results
        )
        switch output.format {
        case .text:
            for result in results {
                print("\(result.passed ? "PASS" : "FAIL") \(result.recipeID)")
                if !result.passed, !result.diagnostics.isEmpty {
                    print(result.diagnostics)
                }
            }
        case .json:
            try CLIOutput.emit(payload, options: output)
        case .jsonl, .rawJSON:
            preconditionFailure("Validated output format is exhaustive.")
        }
        if !payload.passed {
            throw ExitCode.failure
        }
    }
}

struct ApiSymbolSummaryPayload: Encodable {
    let name: String
    let kind: EvaluationsAPISymbolKind
    let availability: [EvaluationsAPIAvailability]
    let sourceLocation: EvaluationsAPISourceLocation

    init(_ symbol: EvaluationsAPISymbol) {
        name = symbol.name
        kind = symbol.kind
        availability = symbol.availability
        sourceLocation = symbol.sourceLocation
    }
}

struct ApiListPayload: Encodable {
    let schemaVersion = EvaluationsAPICatalog.currentSchemaVersion
    let command = "api list"
    let source: EvaluationsAPISource
    let count: Int
    let symbols: [ApiSymbolSummaryPayload]

    init(catalog: EvaluationsAPICatalog) {
        source = catalog.source
        count = catalog.symbols.count
        symbols = catalog.symbols.map(ApiSymbolSummaryPayload.init)
    }
}

struct ApiShowPayload: Encodable {
    let schemaVersion = EvaluationsAPICatalog.currentSchemaVersion
    let command = "api show"
    let source: EvaluationsAPISource
    let symbol: EvaluationsAPISymbol
}

struct ApiExamplePayload: Encodable {
    let schemaVersion = "xceval.authoring-example/v1"
    let command = "api example"
    let recipe: EvaluationAuthoringRecipe
    let typeName: String
    let source: String
}

struct ApiVerifyPayload: Encodable {
    let schemaVersion = "xceval.authoring-verification/v1"
    let command = "api verify"
    let xcode: XcodeInstallation
    let passed: Bool
    let results: [EvaluationAuthoringVerificationResult]

    init(
        xcode: XcodeInstallation,
        results: [EvaluationAuthoringVerificationResult]
    ) {
        self.xcode = xcode
        passed = results.allSatisfy(\.passed)
        self.results = results
    }
}

private func loadAPICatalog(xcode: String?) throws -> EvaluationsAPICatalog {
    let installation = try XcodeLocator.evaluationCapableInstallation(
        preferredPath: xcode
    )
    return try EvaluationsAPIInterfaceDiscovery.catalog(in: installation)
}

private func printAPIHeader(_ source: EvaluationsAPISource) {
    let version = [source.xcodeVersion, source.xcodeBuild]
        .compactMap(\.self)
        .joined(separator: " ")
    print(version.isEmpty ? "Evaluations" : "Evaluations \(version)")
    print("Interface: \(source.interfacePath)")
}

private func prepareVerificationEnvironment() throws {
    guard ProcessInfo.processInfo.environment["CLANG_MODULE_CACHE_PATH"] == nil
    else {
        return
    }
    let cache = FileManager.default.temporaryDirectory
        .appendingPathComponent("xceval-api-module-cache", isDirectory: true)
    try FileManager.default.createDirectory(
        at: cache,
        withIntermediateDirectories: true
    )
    setenv("CLANG_MODULE_CACHE_PATH", cache.path, 1)
}
