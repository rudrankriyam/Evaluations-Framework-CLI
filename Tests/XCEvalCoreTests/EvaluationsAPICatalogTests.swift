import Foundation
import Testing

@testable import XCEvalCore

@Test("Swift interface parser preserves exact declarations and evidence")
func parsesEvaluationsInterfaceCatalog() throws {
    let catalog = EvaluationsAPIInterfaceParser.parse(
        interfaceFixture,
        interfacePath: "/Xcode/Evaluations.swiftinterface",
        frameworkPath: "/Xcode/Evaluations.framework",
        xcodeVersion: "27.0",
        xcodeBuild: "27A5228h"
    )

    #expect(catalog.source.moduleName == "Evaluations")
    #expect(catalog.source.architecture == "arm64")
    #expect(catalog.source.targetTriple == "arm64-apple-macos14.0")
    #expect(catalog.source.compilerVersion == "Apple Swift version 6.4")
    #expect(
        catalog.symbols.map(\.name) == [
            "ToolCallEvaluator",
            "Evaluation",
            "EvaluatorsBuilder"
        ]
    )

    let evaluator = try catalog.requireSymbol(
        named: "Evaluations.ToolCallEvaluator"
    )
    #expect(evaluator.kind == .struct)
    #expect(evaluator.sourceLocation.startLine == 4)
    #expect(evaluator.sourceLocation.endLine == 11)
    #expect(evaluator.availability.count == 2)
    #expect(evaluator.availability[0].platform == "anyAppleOS")
    #expect(evaluator.availability[0].introducedVersion == "27.0")
    #expect(evaluator.availability[1].platform == "tvOS")
    #expect(evaluator.availability[1].isUnavailable)
    #expect(evaluator.declaration.contains("public let allPass"))
    #expect(!catalog.symbols.contains { $0.name == "Nested" })
}

@Test("Type lookup is exact and reports missing symbols")
func requiresExactEvaluationsSymbolNames() throws {
    let catalog = EvaluationsAPIInterfaceParser.parse(
        interfaceFixture,
        interfacePath: "/Xcode/Evaluations.swiftinterface",
        frameworkPath: "/Xcode/Evaluations.framework"
    )

    #expect(catalog.symbol(named: "Evaluation") != nil)
    #expect(catalog.symbol(named: "evaluation") == nil)
    #expect(throws: EvaluationsAPICatalogError.symbolNotFound("Evaluator")) {
        try catalog.requireSymbol(named: "Evaluator")
    }
}

@Test("Interface discovery prefers an exact architecture")
func discoversPreferredEvaluationsInterface() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("xceval-interface-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let moduleDirectory =
        directory
        .appendingPathComponent("Modules/Evaluations.swiftmodule")
    try FileManager.default.createDirectory(
        at: moduleDirectory,
        withIntermediateDirectories: true
    )
    for architecture in ["arm64", "x86_64"] {
        let file = moduleDirectory.appendingPathComponent(
            "\(architecture)-apple-macos.swiftinterface"
        )
        try Data(interfaceFixture.utf8).write(to: file)
    }

    let selected = try EvaluationsAPIInterfaceDiscovery.interfaceURL(
        frameworkURL: directory,
        preferredArchitecture: "x86_64"
    )
    #expect(
        selected.lastPathComponent == "x86_64-apple-macos.swiftinterface"
    )
}

@Test("Recipe catalog covers explicit authoring families")
func exposesDeterministicAuthoringRecipes() throws {
    let recipes = EvaluationAuthoringRecipeCatalog.recipes

    #expect(Set(recipes.map(\.kind)) == Set(EvaluationAuthoringRecipeKind.allCases))
    #expect(recipes.allSatisfy { !$0.semanticInputs.isEmpty })
    #expect(
        recipes.allSatisfy {
            $0.compilationPlan.mode == "swift-typecheck"
        })
    #expect(
        EvaluationAuthoringRecipeCatalog.recipe(for: .toolCall)
            .requirements.contains {
                $0.module == "Evaluations"
                    && $0.symbol == "TrajectoryExpectation"
            }
    )
    let source =
        try EvaluationAuthoringRecipeCatalog
        .recipe(for: .session)
        .template
        .render(typeName: "MySessionEvaluation")
    #expect(source.contains("public struct MySessionEvaluation"))
    #expect(source.contains("session.transcript.structuredTranscript"))
    #expect(!source.contains(EvaluationAuthoringTemplate.typeNameToken))
    #expect(throws: EvaluationAuthoringRecipeError.self) {
        try EvaluationAuthoringRecipeCatalog
            .recipe(for: .session)
            .template
            .render(typeName: "Not Valid")
    }
}

@Test(
    "Authoring recipes typecheck with the selected Evaluations Xcode",
    .enabled(
        if: ProcessInfo.processInfo.environment[
            "XCEVAL_VERIFY_AUTHORING_RECIPES"
        ] == "1"
    )
)
func typechecksAuthoringRecipes() throws {
    let preferredXcode = ProcessInfo.processInfo.environment[
        "XCEVAL_AUTHORING_XCODE"
    ]
    let installation = try XcodeLocator.evaluationCapableInstallation(
        preferredPath: preferredXcode
    )
    let catalog = try EvaluationsAPIInterfaceDiscovery.catalog(
        in: installation
    )
    let toolCallEvaluator = try catalog.requireSymbol(
        named: "ToolCallEvaluator"
    )
    #expect(catalog.source.interfacePath.hasSuffix(".swiftinterface"))
    #expect(toolCallEvaluator.sourceLocation.path == catalog.source.interfacePath)
    #expect(
        toolCallEvaluator.availability.contains {
            $0.platform == "anyAppleOS"
                && $0.introducedVersion == "27.0"
        }
    )
    #expect(
        EvaluationAuthoringRecipeCatalog.validateRequirements(
            against: catalog
        ).isEmpty
    )
    let results = try EvaluationAuthoringRecipeVerifier.verifyAll(
        in: installation
    )

    for result in results {
        #expect(
            result.passed,
            "Recipe \(result.recipeID) failed:\n\(result.diagnostics)"
        )
    }
}

private let interfaceFixture = """
    // swift-interface-format-version: 1.0
    // swift-compiler-version: Apple Swift version 6.4
    // swift-module-flags: -target arm64-apple-macos14.0 -module-name Evaluations
    @available(anyAppleOS 27.0, *)
    @available(tvOS, unavailable)
    public struct ToolCallEvaluator<Input> : Sendable {
      public let allPass: Metric
      public struct Nested {
        public let value: String
      }
    }
    @available(anyAppleOS 27.0, *)
    public protocol Evaluation : Sendable {
      associatedtype Sample
    }
    @_functionBuilder public struct EvaluatorsBuilder<Sample> {
      public static func buildBlock() {}
    }
    """
