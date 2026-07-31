import Foundation

public struct EvaluationAuthoringVerificationResult:
    Codable,
    Equatable,
    Sendable
{
    public let recipeID: String
    public let passed: Bool
    public let xcodeVersion: String?
    public let xcodeBuild: String?
    public let interfacePath: String
    public let command: [String]
    public let diagnostics: String

    public init(
        recipeID: String,
        passed: Bool,
        xcodeVersion: String?,
        xcodeBuild: String?,
        interfacePath: String,
        command: [String],
        diagnostics: String
    ) {
        self.recipeID = recipeID
        self.passed = passed
        self.xcodeVersion = xcodeVersion
        self.xcodeBuild = xcodeBuild
        self.interfacePath = interfacePath
        self.command = command
        self.diagnostics = diagnostics
    }
}

public enum EvaluationAuthoringRecipeVerifier {
    public static func verify(
        _ recipe: EvaluationAuthoringRecipe,
        in installation: XcodeInstallation,
        typeName: String? = nil
    ) throws -> EvaluationAuthoringVerificationResult {
        let catalog = try EvaluationsAPIInterfaceDiscovery.catalog(
            in: installation
        )
        let source = try recipe.template.render(typeName: typeName)
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "xceval-recipe-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent("Recipe.swift")
        try Data(source.utf8).write(to: sourceURL, options: .atomic)
        let frameworkSearchPath = URL(
            fileURLWithPath: catalog.source.frameworkPath
        ).deletingLastPathComponent().path
        let arguments = [
            "--sdk",
            "macosx",
            "swiftc",
            "-typecheck",
            "-parse-as-library",
            "-target",
            "\(catalog.source.architecture)-apple-macos27.0",
            "-F",
            frameworkSearchPath,
            sourceURL.path
        ]
        let result = try ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: arguments,
            environment: XcodeLocator.environment(for: installation)
        )
        let diagnostics = [
            result.standardOutputString,
            result.standardErrorString
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
        return EvaluationAuthoringVerificationResult(
            recipeID: recipe.id,
            passed: result.status == 0,
            xcodeVersion: installation.version,
            xcodeBuild: installation.build,
            interfacePath: catalog.source.interfacePath,
            command: ["/usr/bin/xcrun"] + arguments,
            diagnostics: diagnostics
        )
    }

    public static func verifyAll(
        _ recipes: [EvaluationAuthoringRecipe] =
            EvaluationAuthoringRecipeCatalog.recipes,
        in installation: XcodeInstallation
    ) throws -> [EvaluationAuthoringVerificationResult] {
        try recipes.map { try verify($0, in: installation) }
    }
}
