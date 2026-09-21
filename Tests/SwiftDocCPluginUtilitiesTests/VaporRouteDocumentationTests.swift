// This source file is part of the Swift.org open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for Swift project authors

import Foundation
import XCTest
@testable import SwiftDocCPluginUtilities

final class VaporRouteDocumentationTests: XCTestCase {
    func testCommandOptionsAreValidatedBeforeExtraction() throws {
        XCTAssertNoThrow(try VaporRouteDocumentation.validateOptions(baseURL: nil, endpointsOnly: false, extractorAvailable: false))
        XCTAssertNoThrow(try VaporRouteDocumentation.validateOptions(baseURL: "https://example.test", endpointsOnly: true, extractorAvailable: true))
        XCTAssertThrowsError(try VaporRouteDocumentation.validateOptions(baseURL: nil, endpointsOnly: false, extractorAvailable: true))
        XCTAssertThrowsError(try VaporRouteDocumentation.validateOptions(baseURL: nil, endpointsOnly: true, extractorAvailable: true))
        XCTAssertThrowsError(try VaporRouteDocumentation.validateOptions(baseURL: "https://example.test", endpointsOnly: false, extractorAvailable: false))
    }

    func testCatalogPreservesAuthoredContentAndHandlesFilenameCollision() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("Original.docc")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let authored = original.appendingPathComponent("VaporEndpoints.md")
        try "# Authored endpoints".write(to: authored, atomically: true, encoding: .utf8)
        let generated = directory.appendingPathComponent("generated.md")
        try "# Endpoints".write(to: generated, atomically: true, encoding: .utf8)
        let catalog = try VaporRouteDocumentation.catalog(original: original, generatedPage: generated,
            workingDirectory: directory)
        XCTAssertEqual(try String(contentsOf: authored), "# Authored endpoints")
        XCTAssertEqual(try String(contentsOf: catalog.appendingPathComponent("VaporEndpoints.md")), "# Authored endpoints")
        XCTAssertEqual(try String(contentsOf: catalog.appendingPathComponent("VaporEndpoints-1.md")), "# Endpoints")
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.appendingPathComponent("VaporEndpoints-1.md").path))
    }

    func testBaseURLValidation() throws {
        for url in ["https://api.example.test", "http://localhost:8080/api/v1"] {
            XCTAssertNoThrow(try VaporRouteDocumentation.validate(baseURL: url))
        }
        for url in ["", "/api", "file:///tmp", "https://", "https://user:password@example.test",
                    "https://example.test?key=value", "https://example.test#fragment"] {
            XCTAssertThrowsError(try VaporRouteDocumentation.validate(baseURL: url), url)
        }
    }

    func testFailedExtractionIsNotTreatedAsSuccessfulDocumentation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let graphs = directory.appendingPathComponent("input")
        try FileManager.default.createDirectory(at: graphs, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: graphs.appendingPathComponent("App.symbols.json"))
        let working = directory.appendingPathComponent("working")
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        let stale = working.appendingPathComponent("stale.symbols.json")
        try Data().write(to: stale)
        XCTAssertThrowsError(try VaporRouteDocumentation.generate(executable: URL(fileURLWithPath: "/usr/bin/false"),
            module: "App", sources: [], symbolGraphDirectory: graphs, workingDirectory: working,
            baseURL: "https://example.test"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: graphs.appendingPathComponent("App.symbols.json").path))
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(contentsOf: working.appendingPathComponent("request.json"))) as? [String: Any])
        XCTAssertEqual(request["baseURL"] as? String, "https://example.test")
    }

    func testSuccessfulProcessMustProduceGraph() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let graphs = directory.appendingPathComponent("input")
        try FileManager.default.createDirectory(at: graphs, withIntermediateDirectories: true)
        XCTAssertThrowsError(try VaporRouteDocumentation.generate(executable: URL(fileURLWithPath: "/usr/bin/true"),
            module: "App", sources: [], symbolGraphDirectory: graphs,
            workingDirectory: directory.appendingPathComponent("working"), baseURL: "https://example.test"))
    }
}
