import ArgumentParser
import Foundation
import XCEvalCore

struct ArtifactSelectionOptions: ParsableArguments {
    @Option(
        name: .long,
        help: "Select an artifact by evaluationID when input contains multiple results."
    )
    var evaluationID: String?

    @Option(
        name: .long,
        help: "Select an artifact by resultID when input contains multiple results."
    )
    var resultID: String?

    func select(
        _ artifacts: [EvaluationArtifact]
    ) throws -> [EvaluationArtifact] {
        let selected = artifacts.filter { artifact in
            (evaluationID == nil || artifact.evaluationID == evaluationID)
                && (resultID == nil || artifact.resultID == resultID)
        }
        guard !selected.isEmpty else {
            throw ValidationError(
                "No evaluation artifact matches the requested identifiers."
            )
        }
        return selected
    }
}

func loadArtifacts(path: String) throws -> [EvaluationArtifact] {
    if path == "-" {
        return try EvaluationArtifactLoader.load(
            data: FileHandle.standardInput.readDataToEndOfFile()
        )
    }
    return try EvaluationArtifactLoader.load(from: expandedURL(path))
}

func loadSelectedArtifacts(
    path: String,
    selection: ArtifactSelectionOptions
) throws -> [EvaluationArtifact] {
    try selection.select(loadArtifacts(path: path))
}

func loadSingleArtifact(
    path: String,
    selection: ArtifactSelectionOptions
) throws -> EvaluationArtifact {
    let artifacts = try loadSelectedArtifacts(path: path, selection: selection)
    return try requireSingleArtifact(artifacts)
}

func loadSingleArtifact(path: String) throws -> EvaluationArtifact {
    try requireSingleArtifact(loadArtifacts(path: path))
}

private func requireSingleArtifact(
    _ artifacts: [EvaluationArtifact]
) throws -> EvaluationArtifact {
    guard artifacts.count == 1 else {
        throw ValidationError(
            """
            Input resolved to \(artifacts.count) artifacts. Pass --evaluation-id \
            or --result-id to select one, or use 'xceval list'.
            """
        )
    }
    return artifacts[0]
}

func sanitizedFileComponent(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(
        CharacterSet(charactersIn: "-_.")
    )
    let scalars = value.unicodeScalars.map { scalar in
        allowed.contains(scalar) ? Character(String(scalar)) : "-"
    }
    let result = String(scalars)
    return result.isEmpty ? "evaluation" : result
}
