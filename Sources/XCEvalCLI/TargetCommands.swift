import ArgumentParser
import Foundation
import XCEvalCore

struct TargetsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "targets",
        abstract: "List declared evaluation producer targets."
    )

    @Argument(
        help: "Target manifest. Defaults to .xceval/targets.json."
    )
    var manifestPath = ".xceval/targets.json"

    @OptionGroup var outputOptions: StandardOutputOptions

    mutating func run() throws {
        let output = try outputOptions.resolve()
        let loaded = try loadTargetManifest(manifestPath)
        let payload = TargetsPayload(
            manifestPath: loaded.url.path,
            targets: loaded.manifest.targets
        )

        switch output.format {
        case .text:
            for target in payload.targets {
                print("\(target.id)\t\(target.kind.rawValue)\t\(target.revision)")
            }
        case .json:
            try CLIOutput.emit(payload, options: output)
        case .jsonl, .rawJSON:
            preconditionFailure("Validated output format is exhaustive.")
        }
    }
}

struct TargetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "target",
        abstract: "Describe one declared evaluation producer target."
    )

    @Argument(help: "Stable target ID.")
    var id: String

    @Option(
        name: .long,
        help: "Target manifest. Defaults to .xceval/targets.json."
    )
    var manifest = ".xceval/targets.json"

    @OptionGroup var outputOptions: StandardOutputOptions

    mutating func run() throws {
        let output = try outputOptions.resolve()
        let loaded = try loadTargetManifest(manifest)
        let target = try loaded.manifest.target(id: id)
        let payload = TargetPayload(
            manifestPath: loaded.url.path,
            target: target
        )

        switch output.format {
        case .text:
            print("Target: \(target.id)")
            print("Kind: \(target.kind.rawValue)")
            print("Revision: \(target.revision)")
            print("Command: \(target.argv.joined(separator: " "))")
            for declaredOutput in target.outputs {
                print(
                    "Output: \(declaredOutput.role) "
                        + "\(declaredOutput.path) "
                        + "(\(declaredOutput.format.rawValue))"
                )
            }
        case .json:
            try CLIOutput.emit(payload, options: output)
        case .jsonl, .rawJSON:
            preconditionFailure("Validated output format is exhaustive.")
        }
    }
}

struct EvaluationTargetDocument: Encodable {
    let id: String
    let kind: EvaluationTarget.Kind
    let revision: String
    let workingDirectory: String?
    let argv: [String]
    let environment: EvaluationTargetEnvironment?
    let outputs: [EvaluationTargetOutput]
    let requirements: [EvaluationTargetRequirement]
    let sampleKeyPointer: String?

    init(_ target: EvaluationTarget) {
        id = target.id
        kind = target.kind
        revision = target.revision
        workingDirectory = target.workingDirectory
        argv = target.argv
        environment = target.environment
        outputs = target.outputs
        requirements = target.requirements
        sampleKeyPointer = target.sampleKeyPointer
    }
}

struct TargetsPayload: Encodable {
    let schemaVersion = EvaluationTargetManifest.currentSchemaVersion
    let command = "targets"
    let manifestPath: String
    let count: Int
    let targets: [EvaluationTargetDocument]

    init(manifestPath: String, targets: [EvaluationTarget]) {
        self.manifestPath = manifestPath
        count = targets.count
        self.targets = targets.map(EvaluationTargetDocument.init)
    }
}

struct TargetPayload: Encodable {
    let schemaVersion = EvaluationTargetManifest.currentSchemaVersion
    let command = "target"
    let manifestPath: String
    let target: EvaluationTargetDocument

    init(manifestPath: String, target: EvaluationTarget) {
        self.manifestPath = manifestPath
        self.target = EvaluationTargetDocument(target)
    }
}

func loadTargetManifest(
    _ path: String
) throws -> (url: URL, manifest: EvaluationTargetManifest) {
    let url = expandedURL(path)
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw XCEvalCLIError.manifestNotFound(path: url.path)
    }
    do {
        let manifest = try JSONDecoder().decode(
            EvaluationTargetManifest.self,
            from: Data(contentsOf: url)
        )
        try manifest.validate()
        return (url, manifest)
    } catch {
        throw ValidationError(
            "Invalid target manifest at \(url.path): "
                + error.localizedDescription
        )
    }
}

func resolvePath(_ path: String, relativeTo base: URL) -> URL {
    let expanded = (path as NSString).expandingTildeInPath
    if (expanded as NSString).isAbsolutePath {
        return expandedURL(expanded)
    }
    return base.appendingPathComponent(expanded).standardizedFileURL
}
