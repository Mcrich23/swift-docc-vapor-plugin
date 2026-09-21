// This source file is part of the Swift.org open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for Swift project authors

import Foundation

/// Selects the local type surface reachable from endpoint documentation.
public enum EndpointTypes {
    private static let typeKinds: Set<String> = ["struct", "class", "enum", "protocol", "typealias", "associatedtype"]
    private static let memberKinds: Set<String> = ["property", "typeProperty", "case", "associatedtype"]

    /// Retain the referenced types, their data members, and transitively referenced local types.
    /// Lexical parents are retained only as containers; unrelated nested types and methods are omitted.
    /// Unknown graph fields are preserved when copying retained symbols.
    public static func filter(module: String, referencedTypes roots: Set<String>, swiftGraphs: [Data]) throws -> [Data] {
        // Preserve unknown graph fields and mixins rather than round-tripping a reduced schema.
        let graphs = try swiftGraphs.map { try decodeGraph($0) }
            .filter { ($0["module"] as? [String: Any])?["name"] as? String == module }
        let symbols = Dictionary(graphs.flatMap { $0["symbols"] as? [[String: Any]] ?? [] }.map {
            (identifier($0), $0)
        }, uniquingKeysWith: { first, _ in first })
        let types = symbols.filter { typeKinds.contains(kind($0.value)) }
        let paths = Dictionary(types.map { (path($0.value), $0.key) }, uniquingKeysWith: { first, _ in first })
        let relationships = graphs.flatMap { $0["relationships"] as? [[String: Any]] ?? [] }
        let membership = relationships.filter {
            $0["kind"] as? String == "memberOf" && $0["source"] is String && $0["target"] is String
        }
        let children = Dictionary(grouping: membership, by: { $0["target"] as? String ?? "" })
        let parents = Dictionary(grouping: membership, by: { $0["source"] as? String ?? "" })

        func referencedTypes(in symbol: [String: Any]) -> Set<String> {
            var result = Set<String>()
            func scan(_ value: Any) {
                if let object = value as? [String: Any] {
                    if let id = object["preciseIdentifier"] as? String, types[id] != nil { result.insert(id) }
                    for nested in object.values { scan(nested) }
                } else if let array = value as? [Any] { array.forEach(scan) }
            }
            scan(symbol)
            let scope = Array((symbol["pathComponents"] as? [String] ?? []).dropLast())
            let lines = ((symbol["docComment"] as? [String: Any])?["lines"] as? [[String: Any]] ?? [])
                .compactMap { $0["text"] as? String }
            result.formUnion(linkedTypes(in: lines, scope: scope, module: module, paths: paths))
            return result
        }

        var pending = roots.intersection(types.keys)
        var retained = Set<String>()
        while let id = pending.popFirst() {
            guard retained.insert(id).inserted, let symbol = symbols[id] else { continue }
            pending.formUnion(referencedTypes(in: symbol).subtracting(retained))
            for edge in children[id] ?? [] {
                guard let childID = edge["source"] as? String, let child = symbols[childID],
                      memberKinds.contains(kind(child)) else { continue }
                if !retained.contains(childID) { pending.insert(childID) }
            }
        }

        // Nested types need their lexical parents for stable symbol paths, but not the
        // parents' unrelated members or documentation (for example a route controller).
        var containers = Set<String>()
        pending = retained
        var visited = Set<String>()
        while let id = pending.popFirst() {
            guard visited.insert(id).inserted else { continue }
            for edge in parents[id] ?? [] {
                guard let parent = edge["target"] as? String, symbols[parent] != nil else { continue }
                if !retained.contains(parent) { containers.insert(parent) }
                pending.insert(parent)
            }
        }
        let included = retained.union(containers)
        return try graphs.map { graph in
            var filtered = graph
            filtered["symbols"] = (graph["symbols"] as? [[String: Any]] ?? []).compactMap { symbol -> [String: Any]? in
                let id = identifier(symbol)
                guard included.contains(id) else { return nil }
                if containers.contains(id) {
                    return symbol.filter { ["identifier", "kind", "names", "pathComponents", "accessLevel", "location"].contains($0.key) }
                }
                return symbol
            }
            filtered["relationships"] = (graph["relationships"] as? [[String: Any]] ?? []).filter { edge in
                guard let source = edge["source"] as? String, let target = edge["target"] as? String else { return false }
                return included.contains(source) && (included.contains(target) || symbols[target] == nil)
            }
            return try JSONSerialization.data(withJSONObject: filtered, options: [.sortedKeys])
        }
    }

    static func isType(_ identifier: String) -> Bool {
        typeKinds.contains(identifier.split(separator: ".").last.map(String.init) ?? "")
    }

    /// Resolve authored symbol links in their original lexical scope.
    static func linkedTypes(in lines: [String], scope: [String], module: String, paths: [String: String]) -> Set<String> {
        let expression = try! NSRegularExpression(pattern: "``([^`]+)``")
        var result = Set<String>()
        let knownPaths = Set(paths.keys)
        for line in lines {
            let qualified = HTTPGraph.qualifyLinks(line, scope: scope, module: module, paths: knownPaths)
            for match in expression.matches(in: qualified, range: NSRange(qualified.startIndex..., in: qualified)) {
                guard let range = Range(match.range(at: 1), in: qualified) else { continue }
                var link = String(qualified[range])
                if link.hasPrefix(module + "/") { link.removeFirst(module.count + 1) }
                if let id = paths[link] { result.insert(id) }
            }
        }
        return result
    }

    private static func decodeGraph(_ data: Data) throws -> [String: Any] {
        guard let graph = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ExtractionError("Expected a symbol graph JSON object.")
        }
        return graph
    }

    private static func identifier(_ symbol: [String: Any]) -> String {
        (symbol["identifier"] as? [String: Any])?["precise"] as? String ?? ""
    }
    private static func kind(_ symbol: [String: Any]) -> String {
        ((symbol["kind"] as? [String: Any])?["identifier"] as? String ?? "").split(separator: ".").last.map(String.init) ?? ""
    }
    private static func path(_ symbol: [String: Any]) -> String {
        (symbol["pathComponents"] as? [String] ?? []).joined(separator: "/")
    }
}
