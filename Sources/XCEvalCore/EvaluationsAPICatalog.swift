import Foundation

public struct EvaluationsAPISource: Codable, Equatable, Sendable {
    public let xcodeVersion: String?
    public let xcodeBuild: String?
    public let frameworkPath: String
    public let interfacePath: String
    public let architecture: String
    public let targetTriple: String?
    public let compilerVersion: String?
    public let moduleName: String

    public init(
        xcodeVersion: String? = nil,
        xcodeBuild: String? = nil,
        frameworkPath: String,
        interfacePath: String,
        architecture: String,
        targetTriple: String? = nil,
        compilerVersion: String? = nil,
        moduleName: String = "Evaluations"
    ) {
        self.xcodeVersion = xcodeVersion
        self.xcodeBuild = xcodeBuild
        self.frameworkPath = frameworkPath
        self.interfacePath = interfacePath
        self.architecture = architecture
        self.targetTriple = targetTriple
        self.compilerVersion = compilerVersion
        self.moduleName = moduleName
    }
}

public struct EvaluationsAPISourceLocation: Codable, Equatable, Sendable {
    public let path: String
    public let startLine: Int
    public let endLine: Int

    public init(path: String, startLine: Int, endLine: Int) {
        self.path = path
        self.startLine = startLine
        self.endLine = endLine
    }
}

public struct EvaluationsAPIAvailability: Codable, Equatable, Sendable {
    public let platform: String
    public let introducedVersion: String?
    public let isUnavailable: Bool
    public let rawAttribute: String

    public init(
        platform: String,
        introducedVersion: String?,
        isUnavailable: Bool,
        rawAttribute: String
    ) {
        self.platform = platform
        self.introducedVersion = introducedVersion
        self.isUnavailable = isUnavailable
        self.rawAttribute = rawAttribute
    }
}

public enum EvaluationsAPISymbolKind: String, Codable, Sendable {
    case actor
    case `class`
    case `enum`
    case `protocol`
    case `struct`
}

public struct EvaluationsAPISymbol: Codable, Equatable, Sendable {
    public let name: String
    public let kind: EvaluationsAPISymbolKind
    public let declaration: String
    public let availability: [EvaluationsAPIAvailability]
    public let sourceLocation: EvaluationsAPISourceLocation

    public init(
        name: String,
        kind: EvaluationsAPISymbolKind,
        declaration: String,
        availability: [EvaluationsAPIAvailability],
        sourceLocation: EvaluationsAPISourceLocation
    ) {
        self.name = name
        self.kind = kind
        self.declaration = declaration
        self.availability = availability
        self.sourceLocation = sourceLocation
    }
}

public struct EvaluationsAPICatalog: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = "xceval.evaluations-api/v1"

    public let schemaVersion: String
    public let source: EvaluationsAPISource
    public let symbols: [EvaluationsAPISymbol]

    public init(
        schemaVersion: String = Self.currentSchemaVersion,
        source: EvaluationsAPISource,
        symbols: [EvaluationsAPISymbol]
    ) {
        self.schemaVersion = schemaVersion
        self.source = source
        self.symbols = symbols
    }

    public func symbol(named name: String) -> EvaluationsAPISymbol? {
        let unqualifiedName = name.split(separator: ".").last.map(String.init) ?? name
        return symbols.first { $0.name == unqualifiedName }
    }

    public func requireSymbol(named name: String) throws -> EvaluationsAPISymbol {
        guard let symbol = symbol(named: name) else {
            throw EvaluationsAPICatalogError.symbolNotFound(name)
        }
        return symbol
    }
}

public enum EvaluationsAPICatalogError: LocalizedError, Equatable {
    case frameworkNotFound(String)
    case interfacesNotFound(String)
    case interfaceUnreadable(String)
    case symbolNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .frameworkNotFound(let path):
            "Evaluations.framework was not found at \(path)."
        case .interfacesNotFound(let path):
            "No Evaluations Swift interfaces were found under \(path)."
        case .interfaceUnreadable(let path):
            "The Evaluations Swift interface could not be read at \(path)."
        case .symbolNotFound(let name):
            "Evaluations does not declare a top-level type named '\(name)'."
        }
    }
}

public enum EvaluationsAPIInterfaceDiscovery {
    public static func catalog(
        in installation: XcodeInstallation,
        preferredArchitecture: String? = nil
    ) throws -> EvaluationsAPICatalog {
        guard let frameworkPath = installation.macOSEvaluationsFramework else {
            throw EvaluationsAPICatalogError.frameworkNotFound(
                installation.developerDirectory
            )
        }
        let interfaceURL = try interfaceURL(
            frameworkURL: URL(fileURLWithPath: frameworkPath),
            preferredArchitecture: preferredArchitecture
        )
        guard let contents = try? String(contentsOf: interfaceURL, encoding: .utf8)
        else {
            throw EvaluationsAPICatalogError.interfaceUnreadable(interfaceURL.path)
        }
        return EvaluationsAPIInterfaceParser.parse(
            contents,
            interfacePath: interfaceURL.path,
            frameworkPath: frameworkPath,
            xcodeVersion: installation.version,
            xcodeBuild: installation.build
        )
    }

    public static func interfaceURL(
        frameworkURL: URL,
        preferredArchitecture: String? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard fileManager.fileExists(atPath: frameworkURL.path) else {
            throw EvaluationsAPICatalogError.frameworkNotFound(frameworkURL.path)
        }
        let moduleDirectory =
            frameworkURL
            .appendingPathComponent("Modules")
            .appendingPathComponent("Evaluations.swiftmodule")
        let interfaces =
            (try? fileManager.contentsOfDirectory(
                at: moduleDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ))?
            .filter { $0.pathExtension == "swiftinterface" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        guard !interfaces.isEmpty else {
            throw EvaluationsAPICatalogError.interfacesNotFound(
                moduleDirectory.path
            )
        }

        let architecture = preferredArchitecture ?? hostArchitecture
        if let exact = interfaces.first(where: {
            interfaceArchitecture($0) == architecture
        }) {
            return exact
        }
        if let arm64 = interfaces.first(where: {
            interfaceArchitecture($0) == "arm64"
        }) {
            return arm64
        }
        return interfaces[0]
    }

    private static func interfaceArchitecture(_ url: URL) -> String {
        url.deletingPathExtension()
            .lastPathComponent
            .split(separator: "-", maxSplits: 1)
            .first
            .map(String.init) ?? ""
    }

    private static var hostArchitecture: String {
        #if arch(arm64)
            "arm64"
        #elseif arch(x86_64)
            "x86_64"
        #else
            ""
        #endif
    }
}

public enum EvaluationsAPIInterfaceParser {
    public static func parse(
        _ contents: String,
        interfacePath: String,
        frameworkPath: String,
        xcodeVersion: String? = nil,
        xcodeBuild: String? = nil
    ) -> EvaluationsAPICatalog {
        let lines = contents.components(separatedBy: .newlines)
        let compilerVersion = headerValue(
            in: lines,
            prefix: "// swift-compiler-version:"
        )
        let moduleFlags = headerValue(in: lines, prefix: "// swift-module-flags:")
        let targetTriple = argument(after: "-target", in: moduleFlags)
        let moduleName =
            argument(after: "-module-name", in: moduleFlags) ?? "Evaluations"
        let architecture =
            targetTriple?
            .split(separator: "-", maxSplits: 1)
            .first
            .map(String.init)
            ?? URL(fileURLWithPath: interfacePath)
            .deletingPathExtension()
            .lastPathComponent
            .split(separator: "-", maxSplits: 1)
            .first
            .map(String.init)
            ?? ""
        let source = EvaluationsAPISource(
            xcodeVersion: xcodeVersion,
            xcodeBuild: xcodeBuild,
            frameworkPath: frameworkPath,
            interfacePath: interfacePath,
            architecture: architecture,
            targetTriple: targetTriple,
            compilerVersion: compilerVersion,
            moduleName: moduleName
        )

        var symbols: [EvaluationsAPISymbol] = []
        var depth = 0
        var pendingAttributes: [(line: Int, text: String)] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if depth == 0, let declaration = typeDeclaration(in: line) {
                let startIndex = pendingAttributes.first?.line ?? index
                var endIndex = index
                var declarationDepth = braceDelta(in: line)
                while declarationDepth > 0, endIndex + 1 < lines.count {
                    endIndex += 1
                    declarationDepth += braceDelta(in: lines[endIndex])
                }
                let declarationText = lines[startIndex...endIndex]
                    .joined(separator: "\n")
                symbols.append(
                    EvaluationsAPISymbol(
                        name: declaration.name,
                        kind: declaration.kind,
                        declaration: declarationText,
                        availability: pendingAttributes.compactMap {
                            parseAvailability($0.text)
                        },
                        sourceLocation: EvaluationsAPISourceLocation(
                            path: interfacePath,
                            startLine: startIndex + 1,
                            endLine: endIndex + 1
                        )
                    )
                )
                pendingAttributes.removeAll(keepingCapacity: true)
                index = endIndex + 1
                continue
            }

            if depth == 0, trimmed.hasPrefix("@") {
                pendingAttributes.append((index, trimmed))
                depth += braceDelta(in: line)
                index += 1
                continue
            }

            if depth == 0, !trimmed.isEmpty {
                pendingAttributes.removeAll(keepingCapacity: true)
            }
            depth += braceDelta(in: line)
            index += 1
        }
        return EvaluationsAPICatalog(source: source, symbols: symbols)
    }

    private static func typeDeclaration(
        in line: String
    ) -> (kind: EvaluationsAPISymbolKind, name: String)? {
        let pattern =
            #"\b(?:(?:final|indirect)\s+)?public\s+(?:(?:final|indirect)\s+)?(actor|class|enum|protocol|struct)\s+([A-Za-z_][A-Za-z0-9_]*)"#
        guard
            let expression = try? NSRegularExpression(pattern: pattern),
            let match = expression.firstMatch(
                in: line,
                range: NSRange(line.startIndex..., in: line)
            ),
            let kindRange = Range(match.range(at: 1), in: line),
            let nameRange = Range(match.range(at: 2), in: line),
            let kind = EvaluationsAPISymbolKind(
                rawValue: String(line[kindRange])
            )
        else {
            return nil
        }
        return (kind, String(line[nameRange]))
    }

    private static func parseAvailability(
        _ attribute: String
    ) -> EvaluationsAPIAvailability? {
        guard
            attribute.hasPrefix("@available("),
            attribute.hasSuffix(")")
        else {
            return nil
        }
        let contents =
            attribute
            .dropFirst("@available(".count)
            .dropLast()
        let parts = contents.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2 else { return nil }
        let platformAndVersion = parts[0].split(whereSeparator: \.isWhitespace)
        let detail = parts[1]
        return EvaluationsAPIAvailability(
            platform: platformAndVersion.first.map(String.init) ?? parts[0],
            introducedVersion: platformAndVersion.count > 1
                ? String(platformAndVersion[1])
                : (detail == "*" || detail == "unavailable" ? nil : detail),
            isUnavailable: detail == "unavailable",
            rawAttribute: attribute
        )
    }

    private static func headerValue(
        in lines: [String],
        prefix: String
    ) -> String? {
        lines.first(where: { $0.hasPrefix(prefix) })?
            .dropFirst(prefix.count)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func argument(after flag: String, in value: String?) -> String? {
        guard let value else { return nil }
        let parts = value.split(whereSeparator: \.isWhitespace)
        guard
            let index = parts.firstIndex(of: Substring(flag)),
            parts.indices.contains(index + 1)
        else {
            return nil
        }
        return String(parts[index + 1])
    }

    private static func braceDelta(in line: String) -> Int {
        var delta = 0
        var inString = false
        var escaped = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            let next = line.index(after: index)
            if !inString, character == "/", next < line.endIndex,
                line[next] == "/"
            {
                break
            }
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                delta += 1
            } else if character == "}" {
                delta -= 1
            }
            index = next
        }
        return delta
    }
}
