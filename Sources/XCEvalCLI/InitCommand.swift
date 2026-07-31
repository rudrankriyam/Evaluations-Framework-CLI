import ArgumentParser
import Foundation
import XCEvalCore

struct InitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Create a compilable Xcode 27 Evaluations starter package.",
        discussion: """
            The starter includes an editable JSON dataset, deterministic \
            evaluators, aggregate metrics, a Swift Testing attachment, a direct \
            .xcevalresult producer, a declared agent target, explicit gates, and \
            xceval.pipeline.json.
            """
    )

    @Argument(help: "Feature name, such as SearchQuality or BookTags.")
    var name: String

    @Option(
        name: .long,
        help: "Destination directory. Defaults to <Name>Evaluations."
    )
    var path: String?

    @Flag(
        name: .long,
        help: "Replace an existing destination directory."
    )
    var force = false

    @Option(
        name: .long,
        help: """
            Add a compile-verified authoring template with explicit injected \
            semantics. The runnable deterministic starter remains unchanged.
            """
    )
    var template: AuthoringTemplateOption?

    @OptionGroup var outputOptions: StandardOutputOptions

    mutating func run() throws {
        let output = try outputOptions.resolve()
        let project = try EvaluationStarterProject(
            name: name,
            path: path,
            authoringTemplate: template
        )
        let files = try project.write(force: force)
        let payload = InitPayload(
            name: project.displayName,
            packageName: project.packageName,
            executableName: project.executableName,
            destination: project.destination.path,
            files: files,
            template: template?.rawValue,
            authoringTemplateFile: project.authoringTemplateURL?.path
        )

        switch output.format {
        case .text:
            print("Created \(project.packageName) at \(project.destination.path)")
            if let template, let file = project.authoringTemplateURL {
                print("Authoring template: \(template.rawValue) at \(file.path)")
            }
            print()
            print("Run the complete pipeline:")
            print("  cd \(shellQuoted(project.destination.path))")
            print("  xceval pipeline")
            print()
            print("Run the Swift Testing evaluation and export its report:")
            print(
                "  xceval test --working-directory . -- "
                    + "-scheme \(project.packageName)-Package "
                    + "-destination 'platform=macOS' test"
            )
        case .json:
            try CLIOutput.emit(payload, options: output)
        case .jsonl, .rawJSON:
            preconditionFailure("Validated output format is exhaustive.")
        }
    }
}

private struct EvaluationStarterProject {
    let displayName: String
    let packageName: String
    let evaluationName: String
    let executableTarget: String
    let executableName: String
    let testTarget: String
    let destination: URL
    let authoringTemplate: AuthoringTemplateOption?

    init(
        name: String,
        path: String?,
        authoringTemplate: AuthoringTemplateOption?
    ) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ValidationError("Feature name must not be empty.")
        }
        guard
            trimmed.allSatisfy({
                $0.isASCII
                    && ($0.isLetter
                        || $0.isNumber
                        || $0 == " "
                        || $0 == "-"
                        || $0 == "_")
            })
        else {
            throw ValidationError(
                """
                Feature name may contain ASCII letters, numbers, spaces, \
                hyphens, and underscores.
                """
            )
        }
        displayName = trimmed
        let base = swiftIdentifier(trimmed)
        guard !base.isEmpty else {
            throw ValidationError(
                "Feature name must contain at least one letter or number."
            )
        }
        let packageBase = base == "Evaluations" ? "GeneratedEvaluations" : base
        packageName =
            packageBase.hasSuffix("Evaluations")
            ? packageBase
            : "\(packageBase)Evaluations"
        let evaluationBase = base == "Evaluation" ? "GeneratedEvaluation" : base
        evaluationName =
            evaluationBase.hasSuffix("Evaluation")
            ? evaluationBase
            : "\(evaluationBase)Evaluation"
        executableTarget = "\(base)EvaluateCLI"
        executableName = "\(kebabCase(trimmed))-evaluate"
        testTarget = "\(base)EvaluationsTests"
        destination = expandedURL(path ?? packageName)
        self.authoringTemplate = authoringTemplate
    }

    var authoringTemplateURL: URL? {
        guard authoringTemplate != nil else { return nil }
        return destination.appendingPathComponent(authoringTemplateRelativePath)
    }

    func write(force: Bool) throws -> [String] {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            guard force else {
                throw ValidationError(
                    """
                    Destination already exists at \(destination.path). Pass \
                    --force to replace it.
                    """
                )
            }
            try validateForcedReplacement(
                targets: [destination],
                protecting: [
                    URL(
                        fileURLWithPath: fileManager.currentDirectoryPath,
                        isDirectory: true
                    )
                ]
            )
            try fileManager.removeItem(at: destination)
        }

        let files = try generatedFiles()
        for (relativePath, contents) in files {
            let url = destination.appendingPathComponent(relativePath)
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: url, options: .atomic)
        }
        return files.keys.sorted().map {
            destination.appendingPathComponent($0).path
        }
    }

    private func generatedFiles() throws -> [String: String] {
        var files = [
            "Package.swift": packageManifest,
            "README.md": readme,
            ".gitignore": gitignore,
            ".xceval/targets.json": targetManifest,
            "xceval.pipeline.json": pipelineManifest,
            "Sources/\(packageName)/\(evaluationName).swift": evaluationSource,
            "Sources/\(packageName)/Resources/starter-samples.json": dataset,
            "Sources/\(executableTarget)/main.swift": executableSource,
            "Tests/\(testTarget)/\(evaluationName)Tests.swift": testSource
        ]
        if let authoringTemplate {
            let recipe = EvaluationAuthoringRecipeCatalog.recipe(
                for: authoringTemplate.recipeKind
            )
            files[authoringTemplateRelativePath] = try recipe.template.render(
                typeName: authoringTemplateTypeName
            )
        }
        return files
    }

    private var authoringTemplateTypeName: String {
        "\(evaluationName)Authoring"
    }

    private var authoringTemplateRelativePath: String {
        "Sources/\(packageName)/\(authoringTemplateTypeName).swift"
    }

    private var packageManifest: String {
        template(
            #"""
            // swift-tools-version: 6.2

            import Foundation
            import PackageDescription

            let fileManager = FileManager.default

            func normalizeDeveloperDirectory(_ path: String) -> URL {
                var url = URL(
                    fileURLWithPath: (path as NSString).expandingTildeInPath
                ).standardizedFileURL
                if url.pathExtension == "app" {
                    url.appendPathComponent("Contents/Developer")
                } else if url.lastPathComponent == "Contents" {
                    url.appendPathComponent("Developer")
                }
                return url
            }

            func discoveredDeveloperDirectories(in directory: URL) -> [URL] {
                let fileManager = FileManager.default
                let applications =
                    (try? fileManager.contentsOfDirectory(
                        at: directory,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    )) ?? []
                return applications
                    .filter {
                        $0.pathExtension == "app"
                            && $0.lastPathComponent
                            .localizedCaseInsensitiveContains("xcode")
                    }
                    .sorted { $0.path < $1.path }
                    .map { $0.appendingPathComponent("Contents/Developer") }
            }

            let environment = ProcessInfo.processInfo.environment
            let home = fileManager.homeDirectoryForCurrentUser
            let candidates: [URL]
            if let explicit = environment["DEVELOPER_DIR"] {
                candidates = [normalizeDeveloperDirectory(explicit)]
            } else {
                candidates =
                    discoveredDeveloperDirectories(
                        in: URL(fileURLWithPath: "/Applications")
                    )
                    + discoveredDeveloperDirectories(
                        in: home.appendingPathComponent("Applications")
                    )
                    + discoveredDeveloperDirectories(
                        in: home.appendingPathComponent("Downloads")
                    )
            }

            let developerDirectory = candidates.first { candidate in
                fileManager.fileExists(
                    atPath: candidate
                        .appendingPathComponent(
                            "Platforms/MacOSX.platform/Developer/Library/Frameworks/"
                                + "Evaluations.framework/Evaluations"
                        )
                        .path
                )
            }

            guard let developerDirectory else {
                fputs(
                    """
                    error: Xcode 27 with Evaluations.framework was not found.
                    Set DEVELOPER_DIR to Xcode.app/Contents/Developer.

                    """,
                    stderr
                )
                exit(1)
            }

            let frameworks = developerDirectory
                .appendingPathComponent(
                    "Platforms/MacOSX.platform/Developer/Library/Frameworks"
                )
                .path
            let xcodeContents = developerDirectory
                .deletingLastPathComponent()
                .path
            let swiftSettings: [SwiftSetting] = [
                .unsafeFlags(["-F", frameworks])
            ]
            let linkerSettings: [LinkerSetting] = [
                .unsafeFlags([
                    "-F", frameworks,
                    "-Xlinker", "-rpath",
                    "-Xlinker", xcodeContents
                ]),
                .linkedFramework("Evaluations")
            ]

            let package = Package(
                name: "__PACKAGE__",
                platforms: [.macOS("27.0")],
                products: [
                    .library(
                        name: "__PACKAGE__",
                        targets: ["__PACKAGE__"]
                    ),
                    .executable(
                        name: "__EXECUTABLE_NAME__",
                        targets: ["__EXECUTABLE_TARGET__"]
                    )
                ],
                targets: [
                    .target(
                        name: "__PACKAGE__",
                        resources: [.process("Resources")],
                        swiftSettings: swiftSettings,
                        linkerSettings: linkerSettings
                    ),
                    .executableTarget(
                        name: "__EXECUTABLE_TARGET__",
                        dependencies: ["__PACKAGE__"],
                        swiftSettings: swiftSettings
                    ),
                    .testTarget(
                        name: "__TEST_TARGET__",
                        dependencies: ["__PACKAGE__"],
                        swiftSettings: swiftSettings
                    )
                ]
            )
            """#
        )
    }

    private var evaluationSource: String {
        template(
            #"""
            import Evaluations
            import Foundation

            @available(macOS 27.0, *)
            public struct __EVALUATION__: Evaluation {
                public let nonEmpty = Metric("Non Empty")
                public let exactMatch = Metric("Exact Match")
                public let responseLength = Metric("Response Length")

                public let dataset: JSONLoader<ModelSample<String>>

                public init(datasetURL: URL = StarterDataset.url) {
                    dataset = JSONLoader(url: datasetURL)
                }

                public func subject(
                    from sample: ModelSample<String>
                ) async throws -> ModelSubject<String> {
                    ModelSubject(
                        value: sample.promptDescription.uppercased()
                    )
                }

                public var evaluators: Evaluators {
                    Evaluator { _, subject in
                        subject.value.isEmpty
                            ? nonEmpty.failing(rationale: "Response was empty.")
                            : nonEmpty.passing()
                    }

                    Evaluator { sample, subject in
                        guard let expected = sample.expected else {
                            return exactMatch.ignore(
                                rationale: "No expected value was provided."
                            )
                        }
                        return subject.value == expected
                            ? exactMatch.passing()
                            : exactMatch.failing(
                                rationale: "Expected '\(expected)'."
                            )
                    }

                    Evaluator { _, subject in
                        responseLength.scoring(
                            Double(subject.value.count)
                        )
                    }
                }

                public func aggregateMetrics(
                    using aggregator: inout MetricsAggregator
                ) {
                    aggregator.group("Quality") { group in
                        group.computeMean(of: nonEmpty)
                        group.computeMean(of: exactMatch)
                    }
                    aggregator.group("Distribution") { group in
                        group.computeMean(of: responseLength)
                        group.computeMinimum(of: responseLength)
                        group.computeMaximum(of: responseLength)
                    }
                }
            }

            public enum StarterDataset {
                public static let url: URL = {
                    guard
                        let url = Bundle.module.url(
                            forResource: "starter-samples",
                            withExtension: "json"
                        )
                    else {
                        fputs(
                            "error: Missing starter-samples.json resource.\n",
                            stderr
                        )
                        exit(1)
                    }
                    return url
                }()
            }
            """#
        )
    }

    private var executableSource: String {
        template(
            #"""
            import __PACKAGE__
            import Evaluations
            import Foundation

            @available(macOS 27.0, *)
            @main
            struct __EXECUTABLE_TARGET__ {
                static func main() async {
                    do {
                        let output = try outputDirectory()
                        let selectedDataset = try selectedDataset()
                        defer {
                            if selectedDataset.isTemporary {
                                try? FileManager.default.removeItem(
                                    at: selectedDataset.url
                                )
                            }
                        }
                        let evaluation = __EVALUATION__(
                            datasetURL: selectedDataset.url
                        )
                        let result = try await evaluation.run(
                            info: [
                                "Feature": "__DISPLAY_NAME__",
                                "Dataset": "starter-samples.json",
                                "Purpose": "xceval generated starter"
                            ]
                        )
                        try FileManager.default.createDirectory(
                            at: output,
                            withIntermediateDirectories: true
                        )
                        let url = try result.saveJSON(
                            to: output,
                            includeReportMetadata: true
                        )
                        print(url.path)
                    } catch {
                        fputs(
                            "__EXECUTABLE_NAME__: \(error.localizedDescription)\n",
                            stderr
                        )
                        exit(1)
                    }
                }

                private static func outputDirectory() throws -> URL {
                    let arguments = Array(CommandLine.arguments.dropFirst())
                    guard !arguments.isEmpty else {
                        return URL(fileURLWithPath: ".xceval/results")
                            .standardizedFileURL
                    }
                    guard
                        arguments.count == 2,
                        arguments[0] == "--output"
                    else {
                        throw RunnerError.invalidArguments
                    }
                    return URL(
                        fileURLWithPath:
                            (arguments[1] as NSString).expandingTildeInPath
                    ).standardizedFileURL
                }

                private static func selectedDataset() throws -> (
                    url: URL,
                    isTemporary: Bool
                ) {
                    guard
                        let selectionPath = ProcessInfo.processInfo.environment[
                            "XCEVAL_SELECTION_PATH"
                        ]
                    else {
                        return (StarterDataset.url, false)
                    }
                    let selectionURL = URL(
                        fileURLWithPath:
                            (selectionPath as NSString).expandingTildeInPath
                    ).standardizedFileURL
                    let selection = try JSONDecoder().decode(
                        SelectionDocument.self,
                        from: Data(contentsOf: selectionURL)
                    )
                    let records = try JSONDecoder().decode(
                        [StarterRecord].self,
                        from: Data(contentsOf: StarterDataset.url)
                    )
                    var selectedIndices = Set<Int>()
                    var missing: [String] = []
                    for sample in selection.samples {
                        let matches = records.indices.filter {
                            sample.matches(records[$0])
                        }
                        if matches.isEmpty {
                            missing.append(sample.key)
                        } else {
                            selectedIndices.formUnion(matches)
                        }
                    }
                    guard missing.isEmpty else {
                        throw RunnerError.selectionKeysNotFound(
                            missing.sorted()
                        )
                    }
                    let filtered = records.indices.compactMap {
                        selectedIndices.contains($0) ? records[$0] : nil
                    }
                    let temporaryURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent(
                            "xceval-selection-\(UUID().uuidString).json"
                        )
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [
                        .prettyPrinted,
                        .sortedKeys,
                        .withoutEscapingSlashes
                    ]
                    try encoder.encode(filtered).write(
                        to: temporaryURL,
                        options: .atomic
                    )
                    return (temporaryURL, true)
                }
            }

            private struct SelectionDocument: Decodable {
                let samples: [SelectedSample]
            }

            private struct SelectedSample: Decodable {
                let key: String
                let canonicalKey: String?
                let input: SelectionInput?

                func matches(_ record: StarterRecord) -> Bool {
                    if let exactInput = input?.exactStarterInput {
                        return record.input == exactInput
                    }
                    if let selectedPrompt = input?.prompt {
                        return record.input.prompt == selectedPrompt
                    }
                    if key == record.input.prompt {
                        return true
                    }
                    guard
                        let canonicalKey,
                        let data = canonicalKey.data(using: .utf8),
                        let decoded = try? JSONDecoder().decode(
                            String.self,
                            from: data
                        )
                    else {
                        return false
                    }
                    return decoded == record.input.prompt
                }
            }

            private struct SelectionInput: Decodable {
                let instructions: String?
                let prompt: String?

                var exactStarterInput: StarterInput? {
                    guard let instructions, let prompt else { return nil }
                    return StarterInput(
                        instructions: instructions,
                        prompt: prompt
                    )
                }

                private enum CodingKeys: String, CodingKey {
                    case input
                    case record
                    case instructions
                    case prompt
                    case promptDescription
                }

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(
                        keyedBy: CodingKeys.self
                    )
                    let nestedInput = try? container.decode(
                        StarterInput.self,
                        forKey: .input
                    )
                    let nestedRecord = try? container.decode(
                        StarterInput.self,
                        forKey: .record
                    )
                    let nested = nestedInput ?? nestedRecord
                    instructions =
                        nested?.instructions
                        ?? (try? container.decodeIfPresent(
                            String.self,
                            forKey: .instructions
                        ))
                    prompt =
                        nested?.prompt
                        ?? (try? container.decodeIfPresent(
                            String.self,
                            forKey: .prompt
                        ))
                        ?? (try? container.decodeIfPresent(
                            String.self,
                            forKey: .promptDescription
                        ))
                }
            }

            private struct StarterRecord: Codable, Equatable {
                let input: StarterInput
                let output: StarterOutput
            }

            private struct StarterInput: Codable, Equatable {
                let instructions: String
                let prompt: String
            }

            private struct StarterOutput: Codable, Equatable {
                let value: String
            }

            private enum RunnerError: LocalizedError {
                case invalidArguments
                case selectionKeysNotFound([String])

                var errorDescription: String? {
                    switch self {
                    case .invalidArguments:
                        "Usage: __EXECUTABLE_NAME__ [--output <directory>]"
                    case .selectionKeysNotFound(let keys):
                        "Selection keys were not found: \(keys.joined(separator: ", "))"
                    }
                }
            }
            """#
        )
    }

    private var testSource: String {
        template(
            #"""
            import __PACKAGE__
            import Evaluations
            import Testing

            @available(macOS 27.0, *)
            private let starterEvaluation = __EVALUATION__()

            @available(macOS 27.0, *)
            @Test(
                "__DISPLAY_NAME__ evaluation",
                .evaluates(
                    starterEvaluation,
                    info: ["Purpose": "Starter evaluation attachment"]
                )
            )
            func starterEvaluationTest() async throws {
                let result = EvaluationContext.current.result
                #expect(
                    result.aggregateValue(
                        .mean(of: starterEvaluation.nonEmpty)
                    ) == 1
                )
                #expect(
                    result.aggregateValue(
                        .mean(of: starterEvaluation.exactMatch)
                    ) >= 0.66
                )
            }
            """#
        )
    }

    private var dataset: String {
        """
        [
          {
            "input": {
              "instructions": "Return the prompt in uppercase.",
              "prompt": "alpha"
            },
            "output": {
              "value": "ALPHA"
            }
          },
          {
            "input": {
              "instructions": "Return the prompt in uppercase.",
              "prompt": "beta"
            },
            "output": {
              "value": "BETA"
            }
          },
          {
            "input": {
              "instructions": "Return the prompt in uppercase.",
              "prompt": "gamma"
            },
            "output": {
              "value": "DELTA"
            }
          }
        ]
        """
    }

    private var pipelineManifest: String {
        template(
            #"""
            {
              "schemaVersion": "xceval.pipeline/v1",
              "name": "__DISPLAY_NAME__ evaluation",
              "workingDirectory": ".",
              "artifactsDirectory": ".xceval/pipeline",
              "resultsPath": ".xceval/results",
              "requiresEvaluationsXcode": true,
              "steps": [
                {
                  "name": "evaluate",
                  "command": [
                    "/usr/bin/xcrun",
                    "swift",
                    "run",
                    "--quiet",
                    "__EXECUTABLE_NAME__",
                    "--output",
                    ".xceval/results"
                  ]
                }
              ],
              "selection": {
                "evaluationID": "__EVALUATION__"
              },
              "gates": [
                "Mean of Non Empty==1",
                "Mean of Exact Match>=0.66"
              ]
            }
            """#
        )
    }

    private var targetManifest: String {
        template(
            #"""
            {
              "schemaVersion": "xceval.targets/v1",
              "targets": [
                {
                  "id": "__EXECUTABLE_NAME__",
                  "kind": "command",
                  "workingDirectory": "..",
                  "argv": [
                    "/usr/bin/xcrun",
                    "swift",
                    "run",
                    "--quiet",
                    "__EXECUTABLE_NAME__",
                    "--output",
                    ".xceval/results"
                  ],
                  "environment": {
                    "inherit": ["HOME", "PATH", "TMPDIR"],
                    "set": {}
                  },
                  "outputs": [
                    {
                      "role": "evaluation-result",
                      "path": ".xceval/results",
                      "format": "xcevalresult",
                      "minimumCount": 1
                    }
                  ],
                  "requirements": [
                    {
                      "capability": "apple.evaluations",
                      "minimumVersion": "27.0"
                    }
                  ],
                  "sampleKeyPointer": "/input/prompt"
                }
              ]
            }
            """#
        )
    }

    private var readme: String {
        let base = template(
            #"""
            # __PACKAGE__

            Generated by `xceval init` as a compilable macOS 27 evaluation
            package.

            ## Run the whole pipeline

            ```bash
            xceval pipeline
            ```

            The pipeline:

            1. Runs the typed `__EVALUATION__` producer.
            2. Saves a native `.xcevalresult`.
            3. Validates the persisted artifact.
            4. Writes `report.json`, including the data behind Xcode's
               evaluation report.
            5. Writes metrics, failing samples, and prompt-response datasets.
            6. Applies explicit aggregate gates.

            Results are under `.xceval/pipeline`.

            ## Run as a declared agent target

            ```bash
            xceval targets
            xceval run __EXECUTABLE_NAME__ \
              --operation-id first-run --output json
            ```

            `run --selection <manifest>` sets `XCEVAL_SELECTION_PATH`; this
            starter producer then reruns records by the selected sample input
            identity, with prompt-key compatibility for older manifests.

            ## Run the Swift Testing attachment

            ```bash
            xceval test --working-directory . -- \
              -scheme __PACKAGE__-Package \
              -destination 'platform=macOS' test
            ```

            This auto-selects an Evaluations-capable Xcode, preserves the
            `.xcresult`, and exports its evaluation attachments. Open the
            resulting Xcode test report when you want Apple's visual UI.

            ## Adapt it

            - Replace `starter-samples.json` with 10-30 focused golden, edge,
              adversarial, and known-failure samples.
            - Replace the uppercase subject with the feature under evaluation.
            - Keep deterministic evaluators for computable criteria.
            - Add a model judge only for subjective criteria, then calibrate it
              against human labels before trusting it as a gate.
            - Add known failures to the dataset whenever a regression is found.
            - Add a `baseline` path to `xceval.pipeline.json` to produce
              `comparison.json`.

            The starter intentionally includes one failing sample while its
            aggregate gate passes. This makes failure extraction and report
            inspection visible on the first run.
            """#
        )
        guard let authoringTemplate else { return base }
        let recipe = EvaluationAuthoringRecipeCatalog.recipe(
            for: authoringTemplate.recipeKind
        )
        let inputs = recipe.semanticInputs
            .map { "- `\($0.id)`: \($0.description)" }
            .joined(separator: "\n")
        return base
            + template(
                #"""

                ## Explicit authoring template

                `__EVALUATION__Authoring.swift` contains the compile-verified
                `__AUTHORING_TEMPLATE__` recipe. It is additive: the runnable
                deterministic starter remains the pipeline target until you
                explicitly integrate the injected behavior.

                The template requires product-owned inputs:

                __AUTHORING_INPUTS__
                """#
            )
            .replacingOccurrences(
                of: "__AUTHORING_TEMPLATE__",
                with: authoringTemplate.rawValue
            )
            .replacingOccurrences(of: "__AUTHORING_INPUTS__", with: inputs)
    }

    private var gitignore: String {
        """
        .build/
        .swiftpm/
        .xceval/*
        !.xceval/targets.json
        *.xcresult
        *.xcevalresult
        *.xcevalresults.jsonl
        """
    }

    private func template(_ value: String) -> String {
        value
            .replacingOccurrences(of: "__DISPLAY_NAME__", with: displayName)
            .replacingOccurrences(of: "__PACKAGE__", with: packageName)
            .replacingOccurrences(of: "__EVALUATION__", with: evaluationName)
            .replacingOccurrences(
                of: "__EXECUTABLE_TARGET__",
                with: executableTarget
            )
            .replacingOccurrences(
                of: "__EXECUTABLE_NAME__",
                with: executableName
            )
            .replacingOccurrences(of: "__TEST_TARGET__", with: testTarget)
    }
}

private func swiftIdentifier(_ value: String) -> String {
    let words = value.split {
        !$0.isLetter && !$0.isNumber
    }
    var identifier = words.map { word in
        guard let first = word.first else { return "" }
        return first.uppercased() + word.dropFirst()
    }.joined()
    if identifier.first?.isNumber == true {
        identifier = "Evaluation\(identifier)"
    }
    return identifier
}

private func kebabCase(_ value: String) -> String {
    var result = ""
    var previousWasSeparator = true
    for character in value {
        if character.isLetter || character.isNumber {
            if character.isUppercase, !previousWasSeparator, !result.isEmpty {
                result.append("-")
            }
            result.append(contentsOf: character.lowercased())
            previousWasSeparator = false
        } else if !previousWasSeparator, !result.isEmpty {
            result.append("-")
            previousWasSeparator = true
        }
    }
    return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
}

private func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
