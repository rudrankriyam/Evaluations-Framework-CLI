import ProjectDescription

let evaluationsFrameworkSearchPath =
    "$(PLATFORM_DIR)/Developer/Library/Frameworks"

let sharedSettings: Settings = .settings(
    base: [
        "CODE_SIGNING_ALLOWED": "NO",
        "CODE_SIGNING_REQUIRED": "NO",
        "ENABLE_TESTING_SEARCH_PATHS": "YES",
        "FRAMEWORK_SEARCH_PATHS": .string(evaluationsFrameworkSearchPath),
        "LD_RUNPATH_SEARCH_PATHS": .string("$(DEVELOPER_DIR)/.."),
        "MACOSX_DEPLOYMENT_TARGET": "27.0",
        "SWIFT_DEFAULT_ACTOR_ISOLATION": "nonisolated",
        "SWIFT_STRICT_CONCURRENCY": "complete",
        "SWIFT_VERSION": "6.0"
    ]
)

let evaluationsDependency: TargetDependency = .sdk(
    name: "Evaluations",
    type: .framework,
    status: .required
)

func platformSmokeTarget(
    name: String,
    destinations: Destinations,
    deploymentTargets: DeploymentTargets
) -> Target {
    .target(
        name: name,
        destinations: destinations,
        product: .staticFramework,
        bundleId: "com.example.evaluations-lab.\(name.lowercased())",
        deploymentTargets: deploymentTargets,
        infoPlist: .default,
        sources: ["Sources/PlatformSmoke/**"],
        dependencies: [evaluationsDependency],
        settings: sharedSettings
    )
}

let project = Project(
    name: "EvaluationsLab",
    options: .options(
        automaticSchemesOptions: .enabled(
            codeCoverageEnabled: true,
            testingOptions: [.parallelizable]
        )
    ),
    targets: [
        .target(
            name: "EvaluationsLabSupport",
            destinations: .macOS,
            product: .staticFramework,
            bundleId: "com.example.evaluations-lab.support",
            deploymentTargets: .macOS("27.0"),
            infoPlist: .default,
            sources: ["Sources/Support/**"],
            dependencies: [evaluationsDependency],
            settings: sharedSettings
        ),
        .target(
            name: "EvaluationsLabCLI",
            destinations: .macOS,
            product: .commandLineTool,
            bundleId: "com.example.evaluations-lab.cli",
            deploymentTargets: .macOS("27.0"),
            infoPlist: .default,
            sources: ["Sources/CLI/**"],
            dependencies: [
                .target(name: "EvaluationsLabSupport"),
                evaluationsDependency
            ],
            settings: sharedSettings
        ),
        .target(
            name: "EvaluationsLabTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.example.evaluations-lab.tests",
            deploymentTargets: .macOS("27.0"),
            infoPlist: .default,
            sources: [
                "Tests/**",
                "Sources/AdvancedCoverage/**"
            ],
            dependencies: [
                .target(name: "EvaluationsLabSupport"),
                evaluationsDependency
            ],
            settings: sharedSettings
        ),
        .target(
            name: "EvaluationsLabVerificationTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.example.evaluations-lab.verification-tests",
            deploymentTargets: .macOS("27.0"),
            infoPlist: .default,
            sources: ["Tests/Verification/**"],
            dependencies: [
                .target(name: "EvaluationsLabSupport"),
                evaluationsDependency
            ],
            settings: sharedSettings
        ),
        platformSmokeTarget(
            name: "EvaluationsLabPlatformMacOS",
            destinations: .macOS,
            deploymentTargets: .macOS("27.0")
        ),
        platformSmokeTarget(
            name: "EvaluationsLabPlatformIOSSimulator",
            destinations: .iOS,
            deploymentTargets: .iOS("27.0")
        ),
        platformSmokeTarget(
            name: "EvaluationsLabPlatformVisionOSSimulator",
            destinations: .visionOS,
            deploymentTargets: .visionOS("27.0")
        ),
        platformSmokeTarget(
            name: "EvaluationsLabPlatformWatchOSSimulator",
            destinations: .watchOS,
            deploymentTargets: .watchOS("27.0")
        )
    ],
    schemes: [
        .scheme(
            name: "EvaluationsLabModelTests",
            shared: true,
            buildAction: .buildAction(
                targets: ["EvaluationsLabTests"]
            ),
            testAction: .targets(
                ["EvaluationsLabTests"],
                arguments: .arguments(
                    environmentVariables: [
                        "EVALUATIONS_LAB_RUN_MODEL_TESTS": "1"
                    ]
                )
            )
        )
    ]
)
