import Foundation

/// Validates paths before any caller performs a recursive replacement.
public struct DestructivePathPolicy: Sendable {
    public let allowedRoot: URL
    public let protectedPaths: [URL]

    private let homeDirectory: URL
    private let allowsHomeDirectoryAsRoot: Bool

    public init(
        allowedRoot: URL,
        protectedPaths: [URL] = [],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        allowsHomeDirectoryAsRoot: Bool = false
    ) {
        self.allowedRoot = Self.canonical(allowedRoot)
        self.protectedPaths = protectedPaths.map(Self.canonical)
        self.homeDirectory = Self.canonical(homeDirectory)
        self.allowsHomeDirectoryAsRoot = allowsHomeDirectoryAsRoot
    }

    public func validate(targets: [URL]) throws {
        guard !targets.isEmpty else {
            throw DestructivePathError.emptyTargets
        }
        try validateAllowedRoot()

        let canonicalTargets = targets.map(Self.canonical)
        for target in canonicalTargets {
            try validate(target: target)
        }

        for firstIndex in canonicalTargets.indices {
            for secondIndex in canonicalTargets.indices
            where secondIndex > firstIndex {
                let first = canonicalTargets[firstIndex]
                let second = canonicalTargets[secondIndex]
                if Self.contains(first, second) || Self.contains(second, first) {
                    throw DestructivePathError.overlappingTargets(
                        first.path,
                        second.path
                    )
                }
            }
        }
    }

    private func validateAllowedRoot() throws {
        if allowedRoot.path == "/"
            || (!allowsHomeDirectoryAsRoot && allowedRoot == homeDirectory)
        {
            throw DestructivePathError.broadAllowedRoot(allowedRoot.path)
        }
    }

    private func validate(target: URL) throws {
        guard Self.contains(allowedRoot, target), target != allowedRoot else {
            throw DestructivePathError.outsideAllowedRoot(
                target.path,
                allowedRoot.path
            )
        }
        if target.path == "/" || target == homeDirectory {
            throw DestructivePathError.broadTarget(target.path)
        }
        for protectedPath in protectedPaths
        where Self.contains(target, protectedPath) {
            throw DestructivePathError.protectedPathOverlap(
                target.path,
                protectedPath.path
            )
        }
    }

    static func canonical(_ url: URL) -> URL {
        var existingAncestor = url.standardizedFileURL
        var unresolvedComponents: [String] = []
        let fileManager = FileManager.default

        while !fileManager.fileExists(atPath: existingAncestor.path) {
            let parent = existingAncestor.deletingLastPathComponent()
            guard parent.path != existingAncestor.path else {
                break
            }
            unresolvedComponents.insert(
                existingAncestor.lastPathComponent,
                at: 0
            )
            existingAncestor = parent
        }

        var resolved = existingAncestor.resolvingSymlinksInPath()
        for component in unresolvedComponents {
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL
    }

    static func contains(_ ancestor: URL, _ candidate: URL) -> Bool {
        let ancestorComponents = ancestor.pathComponents
        let candidateComponents = candidate.pathComponents
        guard ancestorComponents.count <= candidateComponents.count else {
            return false
        }
        return zip(ancestorComponents, candidateComponents)
            .allSatisfy(==)
    }
}

public enum DestructivePathError: LocalizedError, Equatable {
    case emptyTargets
    case broadAllowedRoot(String)
    case broadTarget(String)
    case outsideAllowedRoot(String, String)
    case protectedPathOverlap(String, String)
    case overlappingTargets(String, String)

    public var errorDescription: String? {
        switch self {
        case .emptyTargets:
            "At least one destructive target is required."
        case .broadAllowedRoot(let path):
            "The destructive path boundary is too broad: \(path)."
        case .broadTarget(let path):
            "Refusing to mutate broad path \(path)."
        case .outsideAllowedRoot(let target, let root):
            "Destructive target \(target) must be a strict descendant of \(root)."
        case .protectedPathOverlap(let target, let protected):
            "Destructive target \(target) contains protected path \(protected)."
        case .overlappingTargets(let first, let second):
            "Destructive targets overlap: \(first) and \(second)."
        }
    }
}

/// A unique, non-replaceable directory layout for one evaluation attempt.
public struct EvaluationRunDirectoryPlan: Codable, Equatable, Sendable {
    public let runID: String
    public let runsRoot: URL
    public let runDirectory: URL
    public let artifactsDirectory: URL
    public let logsDirectory: URL
    public let provenanceFile: URL
    public let eventsFile: URL

    public static func plan(
        runID: String,
        runsRoot: URL,
        protectedPaths: [URL] = [],
        fileManager: FileManager = .default
    ) throws -> EvaluationRunDirectoryPlan {
        guard isValidRunID(runID) else {
            throw EvaluationRunDirectoryError.invalidRunID(runID)
        }

        let canonicalRoot = DestructivePathPolicy.canonical(runsRoot)
        let runDirectory =
            canonicalRoot
            .appendingPathComponent(runID, isDirectory: true)
            .standardizedFileURL
        let policy = DestructivePathPolicy(
            allowedRoot: canonicalRoot,
            protectedPaths: protectedPaths
        )
        try policy.validate(targets: [runDirectory])

        guard !fileManager.fileExists(atPath: runDirectory.path) else {
            throw EvaluationRunDirectoryError.alreadyExists(
                runDirectory.path
            )
        }

        return EvaluationRunDirectoryPlan(
            runID: runID,
            runsRoot: canonicalRoot,
            runDirectory: runDirectory,
            artifactsDirectory: runDirectory.appendingPathComponent(
                "artifacts",
                isDirectory: true
            ),
            logsDirectory: runDirectory.appendingPathComponent(
                "logs",
                isDirectory: true
            ),
            provenanceFile: runDirectory.appendingPathComponent(
                "provenance.json"
            ),
            eventsFile: runDirectory.appendingPathComponent("events.jsonl")
        )
    }

    private static func isValidRunID(_ runID: String) -> Bool {
        guard
            !runID.isEmpty,
            runID.count <= 128,
            runID != ".",
            runID != "..",
            runID.first?.isLetter == true || runID.first?.isNumber == true
        else {
            return false
        }
        return runID.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "."
        }
    }
}

public enum EvaluationRunDirectoryError: LocalizedError, Equatable {
    case invalidRunID(String)
    case alreadyExists(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRunID(let runID):
            """
            Invalid run identifier '\(runID)'. Use 1-128 letters, numbers, dots, \
            underscores, or hyphens, beginning with a letter or number.
            """
        case .alreadyExists(let path):
            "Run directory already exists and will not be replaced: \(path)."
        }
    }
}
