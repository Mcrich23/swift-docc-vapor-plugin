// This source file is part of the Swift.org open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for Swift project authors

import Foundation
import XCTest
@testable import VaporRoutes

final class EndpointTypesTests: XCTestCase {
    func testRetainsReferencedTypesTheirFieldsAndMinimalNestedContainers() throws {
        func symbol(_ id: String, _ kind: String, _ path: [String], refersTo: String? = nil, comment: String? = nil) -> [String: Any] {
            var result: [String: Any] = [
                "identifier": ["precise": id, "interfaceLanguage": "swift"],
                "kind": ["identifier": "swift." + kind], "pathComponents": path,
                "names": ["title": path.last!], "accessLevel": "internal",
            ]
            if let refersTo { result["declarationFragments"] = [["preciseIdentifier": refersTo]] }
            if let comment { result["docComment"] = ["lines": [["text": comment]]] }
            return result
        }
        let symbols = [
            symbol("controller", "struct", ["Controller"], comment: "Unrelated ``Other``."),
            symbol("response", "struct", ["Controller", "Response"], comment: "See ``Request``."),
            symbol("roleField", "property", ["Controller", "Response", "role"], refersTo: "role"),
            symbol("role", "enum", ["Role"]),
            symbol("memberCase", "case", ["Role", "member"]),
            symbol("request", "struct", ["Request"]),
            symbol("cycle", "property", ["Request", "response"], refersTo: "response"),
            symbol("handler", "method", ["Controller", "handle(req:)"], refersTo: "response"),
            symbol("utility", "method", ["Controller", "Response", "debug()"], refersTo: "other"),
            symbol("other", "struct", ["Other"]),
            symbol("migration", "struct", ["Request", "Migration"]),
        ]
        let relationships = [("response", "controller"), ("handler", "controller"), ("roleField", "response"),
                             ("memberCase", "role"), ("cycle", "request"), ("utility", "response"), ("migration", "request")].map {
            ["source": $0.0, "target": $0.1, "kind": "memberOf"]
        }
        let graph: [String: Any] = ["module": ["name": "App"], "symbols": symbols, "relationships": relationships,
                                   "metadata": ["generator": "fixture"]]
        let output = try EndpointTypes.filter(module: "App", referencedTypes: ["response"],
            swiftGraphs: [JSONSerialization.data(withJSONObject: graph)])
        let filtered = try XCTUnwrap(JSONSerialization.jsonObject(with: output[0]) as? [String: Any])
        let retained = try XCTUnwrap(filtered["symbols"] as? [[String: Any]])
        let identifiers = retained.compactMap { ($0["identifier"] as? [String: String])?["precise"] }
        XCTAssertEqual(Set(identifiers), ["controller", "response", "roleField", "role", "memberCase", "request", "cycle"])
        XCTAssertNil(retained.first { ($0["identifier"] as? [String: String])?["precise"] == "controller" }?["docComment"])
        XCTAssertEqual((filtered["metadata"] as? [String: String])?["generator"], "fixture")
        let edges = try XCTUnwrap(filtered["relationships"] as? [[String: String]])
        XCTAssertTrue(edges.allSatisfy { identifiers.contains($0["source"]!) && identifiers.contains($0["target"]!) })
    }

    func testAuthoredTypeLinksRespectLexicalScope() {
        let paths = ["Input": "global", "Controller/Input": "nested", "Output": "output"]
        XCTAssertEqual(EndpointTypes.linkedTypes(in: ["Uses ``Input`` and ``App/Output`` and ``Unknown``."],
            scope: ["Controller"], module: "App", paths: paths), ["nested", "output"])
    }

    func testMalformedGraphFailsWithAnError() {
        XCTAssertThrowsError(try EndpointTypes.filter(module: "App", referencedTypes: [], swiftGraphs: [Data("[]".utf8)]))
    }

    func testNoReferencedTypesProducesEmptyTypeGraphs() throws {
        let graph: [String: Any] = ["module": ["name": "App"], "symbols": [], "relationships": []]
        let output = try EndpointTypes.filter(module: "App", referencedTypes: [],
            swiftGraphs: [JSONSerialization.data(withJSONObject: graph)])
        let filtered = try XCTUnwrap(JSONSerialization.jsonObject(with: output[0]) as? [String: Any])
        XCTAssertEqual((filtered["symbols"] as? [Any])?.count, 0)
    }
}
