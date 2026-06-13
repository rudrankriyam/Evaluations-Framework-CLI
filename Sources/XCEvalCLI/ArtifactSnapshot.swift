import CryptoKit
import Foundation
import XCEvalCore

struct TestExportOutcome {
    let result: XcodeEvaluationExport?
    let error: String?
}

struct ArtifactStamp: Equatable {
    let size: UInt64
    let modificationDate: Date?
    let contentDigest: String
    let artifactDigests: [String: Int]
}

func artifactSnapshot(at url: URL) -> [String: ArtifactStamp] {
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    guard
        fileManager.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        )
    else {
        return [:]
    }

    let files: [URL]
    if isDirectory.boolValue {
        files = (try? EvaluationArtifactLoader.artifactFiles(in: url)) ?? []
    } else {
        files = [url]
    }
    return Dictionary(
        uniqueKeysWithValues: files.compactMap { file in
            guard
                let attributes = try? fileManager.attributesOfItem(
                    atPath: file.path
                )
            else {
                return nil
            }
            return (
                file.path,
                ArtifactStamp(
                    size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
                    modificationDate: attributes[.modificationDate] as? Date,
                    contentDigest: contentDigest(of: file),
                    artifactDigests: artifactDigestCounts(in: file)
                )
            )
        })
}

func artifactsAddedOrChanged(
    _ artifacts: [EvaluationArtifact],
    comparedTo stamp: ArtifactStamp?
) -> [EvaluationArtifact] {
    var existing = stamp?.artifactDigests ?? [:]
    return artifacts.filter { artifact in
        let digest = artifactContentDigest(artifact)
        guard let count = existing[digest], count > 0 else {
            return true
        }
        existing[digest] = count - 1
        return false
    }
}

private func contentDigest(of file: URL) -> String {
    guard let data = try? Data(contentsOf: file) else { return "" }
    return contentDigest(of: data)
}

private func artifactDigestCounts(in file: URL) -> [String: Int] {
    guard let artifacts = try? EvaluationArtifactLoader.load(from: file) else {
        return [:]
    }
    return artifacts.reduce(into: [:]) { counts, artifact in
        counts[artifactContentDigest(artifact), default: 0] += 1
    }
}

private func artifactContentDigest(_ artifact: EvaluationArtifact) -> String {
    let data =
        (try? JSONValue.object(artifact.root).encodedData())
        ?? artifact.rawData
    return contentDigest(of: data)
}

private func contentDigest(of data: Data) -> String {
    SHA256.hash(data: data).map {
        String(format: "%02x", $0)
    }.joined()
}
