// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "EvaluationsFrameworkCLI",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "XCEvalCore",
            targets: ["XCEvalCore"]
        ),
        .library(
            name: "XCEvalFormat",
            targets: ["XCEvalFormat"]
        ),
        .executable(
            name: "xceval",
            targets: ["XCEvalCLI"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-argument-parser.git",
            from: "1.5.0"
        )
    ],
    targets: [
        .target(
            name: "XCEvalCore",
            dependencies: ["XCEvalFormat"]
        ),
        .target(
            name: "XCEvalFormat"
        ),
        .executableTarget(
            name: "XCEvalCLI",
            dependencies: [
                "XCEvalCore",
                "XCEvalFormat",
                .product(
                    name: "ArgumentParser",
                    package: "swift-argument-parser"
                )
            ]
        ),
        .testTarget(
            name: "XCEvalCoreTests",
            dependencies: ["XCEvalCore"]
        ),
        .testTarget(
            name: "XCEvalFormatTests",
            dependencies: ["XCEvalFormat"]
        ),
        .testTarget(
            name: "XCEvalCLITests",
            dependencies: ["XCEvalCLI"]
        )
    ]
)
