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
                    contentDigest: contentDigest(of: file)
                )
            )
        })
}

private func contentDigest(of file: URL) -> String {
    guard let data = try? Data(contentsOf: file) else { return "" }
    return SHA256.hash(data: data).map {
        String(format: "%02x", $0)
    }.joined()
}
