import Foundation

public struct EvaluationsFrameworkLocation: Codable, Equatable, Sendable {
    public let platform: String
    public let path: String
}

public struct XcodeInstallation: Codable, Equatable, Sendable {
    public let applicationPath: String
    public let developerDirectory: String
    public let version: String?
    public let build: String?
    public let frameworks: [EvaluationsFrameworkLocation]
    public let exportsEvaluations: Bool
    public let exportSchemaVersion: String?

    public var macOSEvaluationsFramework: String? {
        frameworks.first { $0.platform == "macOS" }?.path
    }
}

public enum XcodeLocator {
    private static let platformNames: [(displayName: String, bundleName: String)] = [
        ("macOS", "MacOSX"),
        ("iOS", "iPhoneOS"),
        ("iOS Simulator", "iPhoneSimulator"),
        ("watchOS", "WatchOS"),
        ("watchOS Simulator", "WatchSimulator"),
        ("visionOS", "XROS"),
        ("visionOS Simulator", "XRSimulator"),
        ("tvOS", "AppleTVOS"),
        ("tvOS Simulator", "AppleTVSimulator")
    ]

    public static func installations(
        preferredPath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [XcodeInstallation] {
        inspectCandidates(
            candidateDeveloperDirectories(
                preferredPath: preferredPath,
                environment: environment
            ),
            inspector: inspect
        )
    }

    static func inspectCandidates(
        _ candidates: [URL],
        inspector: (URL) -> XcodeInstallation?
    ) -> [XcodeInstallation] {
        candidates.compactMap(inspector)
    }

    public static func evaluationCapableInstallation(
        preferredPath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> XcodeInstallation {
        if let preferredPath {
            let developerDirectory = normalizeXcodePath(preferredPath)
            guard isXcodeDeveloperDirectory(developerDirectory) else {
                throw XcodeEnvironmentError.invalidPreferredXcodePath(
                    developerDirectory.path
                )
            }
        }
        let installations = installations(
            preferredPath: preferredPath,
            environment: environment
        )
        if let match = installations.first(where: {
            $0.exportsEvaluations && $0.macOSEvaluationsFramework != nil
        }) {
            return match
        }
        if preferredPath != nil {
            throw XcodeEnvironmentError.preferredXcodeDoesNotSupportEvaluations
        }
        throw XcodeEnvironmentError.evaluationsXcodeNotFound
    }

    public static func environment(
        for installation: XcodeInstallation
    ) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["DEVELOPER_DIR"] = installation.developerDirectory
        return environment
    }

    private static func candidateDeveloperDirectories(
        preferredPath: String?,
        environment: [String: String]
    ) -> [URL] {
        var candidates: [URL] = []
        if let preferredPath {
            return [normalizeXcodePath(preferredPath)]
        } else if let developerDirectory = environment["DEVELOPER_DIR"] {
            candidates.append(normalizeXcodePath(developerDirectory))
        }

        if let selected = selectedDeveloperDirectory() {
            candidates.append(selected)
        }

        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let searchDirectories = [
            URL(fileURLWithPath: "/Applications"),
            home.appendingPathComponent("Applications"),
            home.appendingPathComponent("Downloads")
        ]
        for directory in searchDirectories {
            let applications =
                (try? fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )) ?? []
            for application in applications.sorted(by: { $0.path < $1.path }) {
                guard
                    application.pathExtension == "app",
                    application.lastPathComponent
                        .localizedCaseInsensitiveContains("xcode")
                else {
                    continue
                }
                candidates.append(
                    application.appendingPathComponent("Contents/Developer")
                )
            }
        }

        var seen = Set<String>()
        return
            candidates
            .map(\.standardizedFileURL)
            .filter { seen.insert($0.path).inserted }
    }

    private static func selectedDeveloperDirectory() -> URL? {
        guard
            let result = try? ProcessRunner.run(
                executable: URL(fileURLWithPath: "/usr/bin/xcode-select"),
                arguments: ["--print-path"]
            ),
            result.status == 0
        else {
            return nil
        }
        let path = result.standardOutputString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return normalizeXcodePath(path)
    }

    private static func normalizeXcodePath(_ path: String) -> URL {
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

    private static func inspect(_ developerDirectory: URL) -> XcodeInstallation? {
        let fileManager = FileManager.default
        guard isXcodeDeveloperDirectory(developerDirectory) else {
            return nil
        }

        let application =
            developerDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        var environment = ProcessInfo.processInfo.environment
        environment["DEVELOPER_DIR"] = developerDirectory.path

        let version = xcodeVersion(environment: environment)
        let export = evaluationExportSupport(environment: environment)
        return XcodeInstallation(
            applicationPath: application.path,
            developerDirectory: developerDirectory.path,
            version: version.version,
            build: version.build,
            frameworks: evaluationFrameworks(
                developerDirectory: developerDirectory,
                fileManager: fileManager
            ),
            exportsEvaluations: export.available,
            exportSchemaVersion: export.schemaVersion
        )
    }

    private static func isXcodeDeveloperDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(
                atPath: url.path,
                isDirectory: &isDirectory
            ),
            isDirectory.boolValue
        else {
            return false
        }
        return FileManager.default.isExecutableFile(
            atPath: url.appendingPathComponent("usr/bin/xcodebuild").path
        )
    }

    private static func evaluationFrameworks(
        developerDirectory: URL,
        fileManager: FileManager
    ) -> [EvaluationsFrameworkLocation] {
        platformNames.compactMap { platform in
            let framework =
                developerDirectory
                .appendingPathComponent("Platforms")
                .appendingPathComponent("\(platform.bundleName).platform")
                .appendingPathComponent("Developer/Library/Frameworks")
                .appendingPathComponent("Evaluations.framework")
            guard fileManager.fileExists(atPath: framework.path) else {
                return nil
            }
            return EvaluationsFrameworkLocation(
                platform: platform.displayName,
                path: framework.path
            )
        }
    }

    private static func xcodeVersion(
        environment: [String: String]
    ) -> (version: String?, build: String?) {
        let result = try? ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["xcodebuild", "-version"],
            environment: environment
        )
        let lines =
            result?.standardOutputString
            .split(whereSeparator: \.isNewline)
            .map(String.init) ?? []
        let version = lines.first?
            .replacingOccurrences(of: "Xcode ", with: "")
        let build = lines.dropFirst().first?
            .replacingOccurrences(of: "Build version ", with: "")
        return (version, build)
    }

    private static func evaluationExportSupport(
        environment: [String: String]
    ) -> (available: Bool, schemaVersion: String?) {
        let result = try? ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["xcresulttool", "export", "evaluations", "--help"],
            environment: environment
        )
        let help = result?.standardOutputString ?? ""
        let available =
            result?.status == 0
            && help.contains("Export evaluation result attachments")
        let schemaVersion = firstMatch(
            in: help,
            pattern: #"version:\s*([0-9]+\.[0-9]+\.[0-9]+)"#
        )
        return (available, schemaVersion)
    }

    private static func firstMatch(
        in value: String,
        pattern: String
    ) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(value.startIndex..., in: value)
        guard
            let match = expression.firstMatch(in: value, range: range),
            match.numberOfRanges > 1,
            let captureRange = Range(match.range(at: 1), in: value)
        else {
            return nil
        }
        return String(value[captureRange])
    }
}

public enum XcodeEnvironmentError: LocalizedError, Equatable {
    case evaluationsXcodeNotFound
    case invalidPreferredXcodePath(String)
    case preferredXcodeDoesNotSupportEvaluations

    public var errorDescription: String? {
        switch self {
        case .evaluationsXcodeNotFound:
            """
            No Xcode installation with Evaluations.framework and \
            'xcresulttool export evaluations' was found.
            """
        case .invalidPreferredXcodePath(let path):
            """
            The selected path is not an Xcode.app or valid Contents/Developer \
            directory: \(path)
            """
        case .preferredXcodeDoesNotSupportEvaluations:
            "The selected Xcode does not expose Evaluations export tooling."
        }
    }
}
