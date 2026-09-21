// This source file is part of the Swift.org open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for Swift project authors

import Foundation
import SymbolKit

/// Generated HTTP symbols and the local type identities used by their documentation.
public struct EndpointDocumentation {
    /// A symbol graph containing HTTP endpoints and path captures.
    public let symbolGraph: Data
    /// Compiler identities of local types referenced by endpoint signatures and authored comments.
    public let referencedTypes: Set<String>
}

/// Connects registered endpoints to compiler-emitted declarations and documentation.
public enum HTTPGraph {
    /// Generate HTTP symbols and collect type references independently of their rendered presentation.
    public static func generate(module: String, baseURL: String, extraction: inout RouteExtraction,
                                swiftGraphs: [Data], endpointsOnly: Bool = false) throws -> EndpointDocumentation {
        let graphs = try swiftGraphs.map { try JSONDecoder().decode(SymbolGraph.self, from: $0) }
            .filter { $0.module.name == module }
        guard let moduleInfo = graphs.first?.module else {
            throw ExtractionError("No Swift symbol graph was found for '\(module)'.")
        }
        // A declaration can appear in several graphs. Preserve one entry per identity.
        let swiftSymbols = Dictionary(graphs.flatMap { $0.symbols.values }.map { ($0.identifier.precise, $0) },
                                      uniquingKeysWith: { first, _ in first })
        let handlers = Dictionary(grouping: swiftSymbols.values.filter {
            $0.kind.identifier == .method || $0.kind.identifier == .func || $0.kind.identifier == .typeMethod
        }, by: { symbol in
            (symbol.pathComponents.dropLast() + [String(symbol.pathComponents.last?.prefix { $0 != "(" } ?? "")])
                .joined(separator: ".")
        })
        let symbolPaths = Set(swiftSymbols.values.map { $0.pathComponents.joined(separator: "/") })

        let typePaths = Dictionary(swiftSymbols.values.filter {
            EndpointTypes.isType($0.kind.identifier.identifier)
        }.map { ($0.pathComponents.joined(separator: "/"), $0.identifier.precise) },
            uniquingKeysWith: { first, _ in first })
        var referencedTypes = Set<String>()
        var output = Graph(module: moduleInfo)
        for route in extraction.routes {
            let id = "http:\(module):\(route.method):\(route.path)"
            let component = symbolPath(for: route)
            var endpoint = HTTPSymbol(id: id, kind: "httpRequest", title: "\(route.method) \(route.path)", path: [component])
            endpoint.httpEndpoint = .init(method: route.method, baseURL: baseURL, path: route.path)
            endpoint.location = .init(uri: URL(fileURLWithPath: route.file).absoluteString,
                                      position: .init(line: route.line - 1, character: 0))

            var lines: [String] = []
            if let handler = route.handler {
                if let matches = handlers[handler], matches.count == 1, let match = matches.first {
                    lines = endpointComments(match.docComment?.lines.map(\.text) ?? []).map {
                        qualifyLinks($0, scope: Array(match.pathComponents.dropLast()), module: module, paths: symbolPaths)
                    }
                    referencedTypes.formUnion(EndpointTypes.linkedTypes(
                        in: lines, scope: [], module: module, paths: typePaths))
                    let path = ([module] + match.pathComponents).joined(separator: "/")
                    if lines.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                        lines = endpointsOnly ? ["\(route.method) endpoint at `\(route.path)`."] : ["Calls ``\(path)``."]
                    }
                    if !endpointsOnly { lines += ["", "## Swift Handler", "", "``\(path)``"] }
                    if let signature = match.mixins[SymbolGraph.Symbol.FunctionSignature.mixinKey] as? SymbolGraph.Symbol.FunctionSignature,
                       !signature.returns.isEmpty {
                        referencedTypes.formUnion(signature.returns.compactMap { fragment in
                            guard let id = fragment.preciseIdentifier, let symbol = swiftSymbols[id],
                                  EndpointTypes.isType(symbol.kind.identifier.identifier) else { return nil }
                            return id
                        })
                        lines += ["", "## Swift Return Type", ""]
                        let paths = Set(signature.returns.compactMap { fragment -> String? in
                            guard let id = fragment.preciseIdentifier, let type = swiftSymbols[id] else { return nil }
                            return ([module] + type.pathComponents).joined(separator: "/")
                        })
                        let spelling = signature.returns.map(\.spelling).joined()
                        let directType = signature.returns.compactMap { fragment in
                            fragment.preciseIdentifier.flatMap { swiftSymbols[$0] }
                        }.first { type in
                            let qualifiedName = type.pathComponents.joined(separator: ".")
                            return spelling == qualifiedName || spelling == module + "." + qualifiedName
                                || spelling == type.pathComponents.last
                        }
                        if let type = directType {
                            // A simple or qualified local type needs only its symbol link.
                            lines.append("``\(([module] + type.pathComponents).joined(separator: "/"))``")
                        } else {
                            // Preserve wrappers such as Page<DTO>, [DTO], and DTO?.
                            lines += ["`\(spelling)`", ""]
                            lines += paths.sorted().map { "- ``\($0)``" }
                        }
                    }
                } else {
                    extraction.diagnostics.append(.init(file: route.file, line: route.line,
                        message: "\(route.method) \(route.path): no unique Swift symbol for '\(handler)'. Include its access level with --symbol-graph-minimum-access-level."))
                }
            }
            if let summary = route.summary {
                referencedTypes.formUnion(EndpointTypes.linkedTypes(in: [summary], scope: [], module: module, paths: typePaths))
                lines = [summary, ""] + lines
            }
            if lines.isEmpty { lines = ["\(route.method) endpoint at `\(route.path)`."] }
            let parameterComments = extractPathParameterComments(from: &lines, names: Set(route.pathParameters))
            for name in parameterComments.keys.sorted() {
                let comments = parameterComments[name]!
                lines += ["", "- HTTPParameter \(name): \(comments.first ?? "")"]
                lines += comments.dropFirst().map { "  " + $0 }
            }
            endpoint.docComment = .init(lines.map { .init(text: $0, range: nil) })
            output.symbols.append(endpoint)

            for name in Set(route.pathParameters).sorted() {
                let parameterID = id + "@path=" + name
                var parameter = HTTPSymbol(id: parameterID, kind: "httpParameter", title: name, path: [component, name])
                parameter.httpParameterSource = "path"
                // Captures are text; don't infer conversion or validation from their names.
                parameter.declarationFragments = [.init(kind: .text, spelling: "string", preciseIdentifier: nil)]
                output.symbols.append(parameter)
                output.relationships.append(.init(source: parameterID, target: id, kind: .memberOf, targetFallback: nil))
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try EndpointDocumentation(symbolGraph: encoder.encode(output), referencedTypes: referencedTypes)
    }

    /// Move a conventional path-parameter list into the native HTTP parameter table.
    /// Preserve unfamiliar Markdown as discussion rather than dropping authored content.
    static func extractPathParameterComments(from lines: inout [String], names: Set<String>) -> [String: [String]] {
        guard !names.isEmpty else { return [:] }
        var fence: Character?
        var start: Int?
        for (index, line) in lines.enumerated() {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("```") || text.hasPrefix("~~~") {
                if fence == text.first { fence = nil }
                else if fence == nil { fence = text.first }
            } else if fence == nil && text == "## Path Parameters" {
                start = index
                break
            }
        }
        guard let start else { return [:] }
        let end = lines.indices.dropFirst(start + 1).first {
            lines[$0].hasPrefix("## ") || lines[$0].hasPrefix("# ")
        } ?? lines.endIndex
        var comments: [String: [String]] = [:]
        var current: String?
        let item = try! NSRegularExpression(pattern: "^[-*] `([^`]+)`: ?(.*)$")
        for line in lines[(start + 1)..<end] {
            if let match = item.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let nameRange = Range(match.range(at: 1), in: line),
               let descriptionRange = Range(match.range(at: 2), in: line) {
                let name = String(line[nameRange])
                guard names.contains(name), comments[name] == nil else {
                    lines[start] = "## Path Parameter Details"
                    return [:]
                }
                current = name
                comments[name] = [String(line[descriptionRange])]
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if let current { comments[current, default: []].append("") }
            } else if let current, line.hasPrefix("  ") {
                comments[current, default: []].append(String(line.dropFirst(2)))
            } else {
                lines[start] = "## Path Parameter Details"
                return [:]
            }
        }
        guard !comments.isEmpty else {
            lines[start] = "## Path Parameter Details"
            return [:]
        }
        lines.removeSubrange(start..<end)
        return comments
    }

    /// Curate endpoints using DocC topic sections, without changing their symbol paths.
    public static func endpointCuration(module: String, routes: [ExtractedRoute]) -> String {
        let groups = Dictionary(grouping: routes) { route in
            route.path.split(separator: "/").first.map { "/" + $0 } ?? "/"
        }
        var lines = ["# Endpoints", "", "Browse HTTP endpoints by route prefix.", "", "## Topics"]
        for prefix in groups.keys.sorted() {
            let title = prefix.map { "\\`*_[]<>#".contains($0) ? "\\" + String($0) : String($0) }.joined()
            lines += ["", "### \(title)", ""]
            for route in groups[prefix]!.sorted(by: { ($0.path, $0.method) < ($1.path, $1.method) }) {
                lines.append("- ``\(module)/\(symbolPath(for: route))``")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func symbolPath(for route: ExtractedRoute) -> String {
        // Escape non-alphanumeric bytes to distinguish punctuation in paths.
        "HTTP-\(route.method)-" + route.path.utf8.map { byte in
            ((65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte))
                ? String(UnicodeScalar(byte)) : String(format: "_%02X", byte)
        }.joined()
    }

    // Copied comments keep the handler's lexical scope, even when mounted at several URLs.
    static func qualifyLinks(_ line: String, scope: [String], module: String, paths: Set<String>) -> String {
        let expression = try! NSRegularExpression(pattern: "``([^`]+)``")
        var result = line
        for match in expression.matches(in: line, range: NSRange(line.startIndex..., in: line)).reversed() {
            guard let range = Range(match.range(at: 1), in: result) else { continue }
            let link = String(result[range])
            for depth in stride(from: scope.count, through: 0, by: -1) {
                let candidate = (Array(scope.prefix(depth)) + [link]).joined(separator: "/")
                if paths.contains(candidate) {
                    result.replaceSubrange(range, with: "\(module)/\(candidate)")
                    break
                }
            }
        }
        return result
    }

    /// Remove Swift parameter fields without discarding later discussion or examples.
    static func endpointComments(_ original: [String]) -> [String] {
        var skippingParameters = false
        var lines: [String] = []
        for line in original {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- Parameters:") || trimmed.hasPrefix("- Parameter ") {
                skippingParameters = true
                continue
            }
            if skippingParameters {
                if trimmed.isEmpty || line.first?.isWhitespace == true { continue }
                skippingParameters = false
            }
            if trimmed.hasPrefix("- Returns:") {
                lines += ["", "## Return Value", "", String(trimmed.dropFirst("- Returns:".count)).trimmingCharacters(in: .whitespaces)]
            } else {
                lines.append(line)
            }
        }
        if !lines.isEmpty {
            // A handler can be mounted under several prefixes; don't copy its original URL.
            lines[0] = lines[0].replacingOccurrences(
                of: "^(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS|CONNECT|TRACE) /\\S*\\s+", with: "", options: .regularExpression)
        }
        return lines
    }
}

public struct ExtractionError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

private struct Graph: Encodable {
    let metadata = SymbolGraph.Metadata(formatVersion: .init(major: 0, minor: 6, patch: 0), generator: "vapor-route-extract")
    let module: SymbolGraph.Module
    var symbols: [HTTPSymbol] = []
    var relationships: [SymbolGraph.Relationship] = []
}

/// HTTP fields aren't available in the plugin's minimum supported SymbolKit release.
/// Reuse its common graph types and encode only the additional HTTP fields here.
private struct HTTPSymbol: Encodable {
    let identifier: SymbolGraph.Symbol.Identifier
    let kind: SymbolGraph.Symbol.Kind
    let names: SymbolGraph.Symbol.Names
    let pathComponents: [String]
    let accessLevel = "public"
    var docComment: SymbolGraph.LineList?
    var location: SymbolGraph.Symbol.Location?
    var httpEndpoint: Endpoint?
    var httpParameterSource: String?
    var declarationFragments: [SymbolGraph.Symbol.DeclarationFragments.Fragment]?

    init(id: String, kind: String, title: String, path: [String]) {
        // These endpoints derive from Swift code, not another representation of the module.
        // Keeping its language lets DocC curate them beside their Swift handlers and types.
        identifier = .init(precise: id, interfaceLanguage: "swift")
        self.kind = .init(parsedIdentifier: .init(rawValue: kind),
                          displayName: kind == "httpRequest" ? "Web Service Endpoint" : "HTTP Parameter")
        names = .init(title: title, navigator: nil, subHeading: nil, prose: nil)
        pathComponents = path
    }

    struct Endpoint: Encodable {
        let method: String
        let baseURL: String
        let path: String
    }
}
