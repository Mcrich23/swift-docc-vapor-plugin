// This source file is part of the Swift.org open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for Swift project authors

import Foundation
import XCTest

#if swift(>=5.9)
final class VaporRoutesTests: ConcurrencyRequiringTestCase {
    func testEndpointsAreDiscoverableAndRemovedRoutesDoNotPersist() throws {
        let fixture = try setupTemporaryDirectoryForFixture(named: "VaporRoutes")
        let result = try swiftPackage("generate-vapor-documentation", "--target", "Server",
                                      "--vapor-routes", "https://example.test/api", workingDirectory: fixture)
        result.assertExitStatusEquals(0)
        let archive = try XCTUnwrap(result.onlyOutputArchive)
        let expected = Set(["GET /health", "GET /items", "GET /items/:id",
                            "GET /admin/:userID/items", "GET /admin/:userID/items/:id"])
        XCTAssertEqual(try endpointTitles(in: archive), expected)

        let index = try object(at: archive.appendingPathComponent("index/index.json"))
        let languages = try XCTUnwrap(index["interfaceLanguages"] as? [String: [[String: Any]]])
        let swift = try XCTUnwrap(languages["swift"])
        let endpointGroups = descendants(swift).filter { $0["title"] as? String == "Endpoints" }
        XCTAssertEqual(endpointGroups.count, 1)
        let groupedChildren = try XCTUnwrap(endpointGroups.first?["children"] as? [[String: Any]])
        XCTAssertEqual(groupedChildren.filter { $0["type"] as? String == "groupMarker" }.compactMap { $0["title"] as? String },
                       ["/admin", "/health", "/items"])
        XCTAssertEqual(Set(descendants(groupedChildren).compactMap { $0["title"] as? String }).intersection(expected), expected)
        XCTAssertEqual(Set(descendants(swift).compactMap { $0["title"] as? String }).intersection(expected), expected)

        let page = try object(at: archive.appendingPathComponent("data/documentation/server/http-get-_2fitems.json"))
        let references = try XCTUnwrap(page["references"] as? [String: [String: Any]])
        XCTAssertTrue(references.values.contains { $0["title"] as? String == "index(req:)" })
        XCTAssertTrue(references.values.contains { $0["title"] as? String == "Item" })
        let abstract = try XCTUnwrap(page["abstract"] as? [[String: String]])
        XCTAssertEqual(abstract.first?["text"], "List available items.")

        let focused = try swiftPackage("generate-vapor-documentation", "--target", "Server",
                                       "--vapor-routes", "https://example.test/api", "--vapor-endpoints-only",
                                       workingDirectory: fixture)
        focused.assertExitStatusEquals(0)
        let focusedArchive = try XCTUnwrap(focused.onlyOutputArchive)
        XCTAssertEqual(try endpointTitles(in: focusedArchive), expected)
        let focusedPage = try object(at: focusedArchive.appendingPathComponent("data/documentation/server/http-get-_2fitems.json"))
        let focusedReferences = try XCTUnwrap(focusedPage["references"] as? [String: [String: Any]])
        XCTAssertTrue(focusedReferences.values.contains { $0["title"] as? String == "Item" })
        XCTAssertFalse(focusedReferences.values.contains { $0["title"] as? String == "index(req:)" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: focusedArchive.appendingPathComponent("data/documentation/server/itemcontroller.json").path))

        let missingBaseURL = try swiftPackage("generate-vapor-documentation", "--target", "Server",
                                             "--vapor-endpoints-only", workingDirectory: fixture)
        XCTAssertNotEqual(missingBaseURL.exitStatus, 0)
        XCTAssertTrue((missingBaseURL.standardOutput + missingBaseURL.standardError)
            .contains("--vapor-endpoints-only requires --vapor-routes"))

        let source = fixture.appendingPathComponent("Sources/Server/Server.swift")
        let original = try String(contentsOf: source)
        try original.replacingOccurrences(of: "    app.get(\"health\") { _ in \"OK\" }\n", with: "")
            .write(to: source, atomically: true, encoding: .utf8)
        let rebuilt = try swiftPackage("generate-vapor-documentation", "--target", "Server",
                                       "--vapor-routes", "https://example.test/api", workingDirectory: fixture)
        rebuilt.assertExitStatusEquals(0)
        XCTAssertEqual(try endpointTitles(in: XCTUnwrap(rebuilt.onlyOutputArchive)), expected.subtracting(["GET /health"]))

        let ordinary = try swiftPackage("generate-documentation", "--target", "Server", workingDirectory: fixture)
        ordinary.assertExitStatusEquals(0)
        XCTAssertTrue(try endpointTitles(in: XCTUnwrap(ordinary.onlyOutputArchive)).isEmpty)

        let dynamic = original.replacingOccurrences(of: "func routes(_ app: Application) throws {", with: """
        func routes(_ app: Application) throws {
            let path: PathComponent = "computed"
            app.get(path) { _ in "OK" }
        """)
        try dynamic.write(to: source, atomically: true, encoding: .utf8)
        let strict = try swiftPackage("generate-vapor-documentation", "--target", "Server",
                                      "--vapor-routes", "https://example.test/api", "--warnings-as-errors",
                                      workingDirectory: fixture)
        XCTAssertNotEqual(strict.exitStatus, 0)
        // SwiftPM forwards subprocess diagnostics as plugin output, which can use stdout.
        let diagnostics = strict.standardOutput + strict.standardError
        XCTAssertTrue(diagnostics.contains("dynamic route path"), diagnostics)
        XCTAssertTrue(diagnostics.contains("Route extraction produced warnings"), diagnostics)
    }

    private func object(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func endpointTitles(in archive: URL) throws -> Set<String> {
        let directory = archive.appendingPathComponent("data/documentation/server")
        return try Set(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.compactMap { file in
                let page = try object(at: file)
                guard let metadata = page["metadata"] as? [String: Any], metadata["symbolKind"] as? String == "httpRequest" else { return nil }
                return metadata["title"] as? String
            })
    }

    private func descendants(_ nodes: [[String: Any]]) -> [[String: Any]] {
        nodes.flatMap { [$0] + descendants($0["children"] as? [[String: Any]] ?? []) }
    }
}
#endif
