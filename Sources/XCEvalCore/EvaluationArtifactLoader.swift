import Foundation

public enum EvaluationArtifactLoader {
    public static func load(from url: URL) throws -> [EvaluationArtifact] {
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(
                atPath: url.path,
                isDirectory: &isDirectory
            )
        else {
            throw EvaluationArtifactLoaderError.pathDoesNotExist(url.path)
        }

        if isDirectory.boolValue {
            let files = try artifactFiles(in: url)
            let artifacts = try files.flatMap(loadFile)
            guard !artifacts.isEmpty else {
                throw EvaluationArtifactLoaderError.noArtifacts(url.path)
            }
            return artifacts
        }
        return try loadFile(url)
    }

    public static func load(
        data: Data,
        sourceURL: URL = URL(fileURLWithPath: "<stdin>")
    ) throws -> [EvaluationArtifact] {
        if let value = try? JSONValue.decode(data) {
            switch value {
            case .object:
                return [
                    try EvaluationArtifact(data: data, sourceURL: sourceURL)
                ]
            case .array(let values):
                return try values.enumerated().map { index, value in
                    try EvaluationArtifact(
                        data: try value.encodedData(),
                        sourceURL: sourceURL,
                        sourceLine: index + 1
                    )
                }
            default:
                break
            }
        }

        let lines = data.split(
            separator: 0x0A,
            omittingEmptySubsequences: false
        )
        var artifacts: [EvaluationArtifact] = []
        for (index, line) in lines.enumerated() {
            let trimmed = Data(line).trimmingJSONWhitespace()
            guard !trimmed.isEmpty else { continue }
            do {
                artifacts.append(
                    try EvaluationArtifact(
                        data: trimmed,
                        sourceURL: sourceURL,
                        sourceLine: index + 1
                    )
                )
            } catch {
                throw EvaluationArtifactLoaderError.invalidJSONLine(
                    source: sourceURL.path,
                    line: index + 1,
                    message: error.localizedDescription
                )
            }
        }
        guard !artifacts.isEmpty else {
            throw EvaluationArtifactLoaderError.noArtifacts(sourceURL.path)
        }
        return artifacts
    }

    public static func artifactFiles(in directory: URL) throws -> [URL] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            throw EvaluationArtifactLoaderError.cannotEnumerate(directory.path)
        }

        var files: [URL] = []
        for case let file as URL in enumerator
        where ["xcevalresult", "jsonl"].contains(file.pathExtension) {
            files.append(file)
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func loadFile(_ url: URL) throws -> [EvaluationArtifact] {
        let data = try Data(contentsOf: url)
        if url.pathExtension == "xcevalresult" {
            return [try EvaluationArtifact(data: data, sourceURL: url)]
        }
        return try load(data: data, sourceURL: url)
    }
}

public enum EvaluationArtifactLoaderError: LocalizedError {
    case pathDoesNotExist(String)
    case cannotEnumerate(String)
    case invalidJSONLine(source: String, line: Int, message: String)
    case noArtifacts(String)

    public var errorDescription: String? {
        switch self {
        case .pathDoesNotExist(let path):
            "The evaluation input does not exist: \(path)"
        case .cannotEnumerate(let path):
            "Unable to enumerate evaluation artifacts under: \(path)"
        case .invalidJSONLine(let source, let line, let message):
            "Invalid evaluation JSON at \(source):\(line): \(message)"
        case .noArtifacts(let source):
            "No evaluation artifacts were found in: \(source)"
        }
    }
}

extension Data {
    fileprivate func trimmingJSONWhitespace() -> Data {
        guard
            let first = firstIndex(where: { !$0.isJSONWhitespace }),
            let last = lastIndex(where: { !$0.isJSONWhitespace })
        else {
            return Data()
        }
        return self[first...last]
    }
}

extension UInt8 {
    fileprivate var isJSONWhitespace: Bool {
        self == 0x20 || self == 0x09 || self == 0x0A || self == 0x0D
    }
}
