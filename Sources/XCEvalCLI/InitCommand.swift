import ArgumentParser
import Foundation

struct InitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Create a compilable Xcode 27 Evaluations starter package.",
        discussion: """
            The starter includes an editable JSON dataset, deterministic \
            evaluators, aggregate metrics, a Swift Testing attachment, a direct \
            .xcevalresult producer, explicit gates, and xceval.pipeline.json.
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

    @OptionGroup var outputOptions: StandardOutputOptions

    mutating func run() throws {
        let output = try outputOptions.resolve()
        let project = try EvaluationStarterProject(name: name, path: path)
        let files = try project.write(force: force)
        let payload = InitPayload(
            name: project.displayName,
            packageName: project.packageName,
            executableName: project.executableName,
            destination: project.destination.path,
            files: files
        )

        switch output.format {
        case .text:
            print("Created \(project.packageName) at \(project.destination.path)")
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

    init(name: String, path: String?) throws {
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
            try fileManager.removeItem(at: destination)
        }

        let files = generatedFiles()
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

    private func generatedFiles() -> [String: String] {
        [
            "Package.swift": packageManifest,
            "README.md": readme,
            ".gitignore": gitignore,
            "xceval.pipeline.json": pipelineManifest,
            "Sources/\(packageName)/\(evaluationName).swift": evaluationSource,
            "Sources/\(packageName)/Resources/starter-samples.json": dataset,
            "Sources/\(executableTarget)/main.swift": executableSource,
            "Tests/\(testTarget)/\(evaluationName)Tests.swift": testSource
        ]
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
                fatalError(
                    """
                    Xcode 27 with Evaluations.framework was not found.
                    Set DEVELOPER_DIR to Xcode.app/Contents/Developer.
                    """
                )
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
                        group.computeVariance(of: responseLength)
                        group.computeStandardDeviation(of: responseLength)
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
                        fatalError("Missing starter-samples.json resource.")
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
                        let evaluation = __EVALUATION__()
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
            }

            private enum RunnerError: LocalizedError {
                case invalidArguments

                var errorDescription: String? {
                    "Usage: __EXECUTABLE_NAME__ [--output <directory>]"
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

    private var readme: String {
        template(
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
    }

    private var gitignore: String {
        """
        .build/
        .swiftpm/
        .xceval/
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
