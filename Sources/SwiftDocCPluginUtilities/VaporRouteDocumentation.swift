// This source file is part of the Swift.org open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for Swift project authors

import Foundation

struct VaporRouteExtractionError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

/// Adds route symbol graphs to a private copy of the target's documentation inputs.
enum VaporRouteDocumentation {
    /// Validate command selection before building the user's target.
    static func validateOptions(baseURL: String?, endpointsOnly: Bool, extractorAvailable: Bool) throws {
        if endpointsOnly && baseURL == nil {
            throw VaporRouteExtractionError("--vapor-endpoints-only requires --vapor-routes <base-url>.")
        }
        if let baseURL {
            guard extractorAvailable else {
                throw VaporRouteExtractionError("Use generate-vapor-documentation or preview-vapor-documentation with --vapor-routes (requires Swift 5.9 or later).")
            }
            try validate(baseURL: baseURL)
        } else if extractorAvailable {
            throw VaporRouteExtractionError("Vapor documentation requires --vapor-routes <base-url>.")
        }
    }

    static func validate(baseURL: String) throws {
        guard let url = URLComponents(string: baseURL),
              url.scheme == "http" || url.scheme == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw VaporRouteExtractionError("--vapor-routes requires an absolute HTTP(S) base URL without credentials, query, or fragment.")
        }
    }

    /// Build a private catalog so generated curation never modifies authored documentation.
    static func catalog(original: URL?, generatedPage: URL, workingDirectory: URL) throws -> URL {
        let catalog = workingDirectory.appendingPathComponent("Routes.docc", isDirectory: true)
        if let original {
            try FileManager.default.copyItem(at: original, to: catalog)
        } else {
            try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: true)
        }
        var destination = catalog.appendingPathComponent("VaporEndpoints.md")
        // Keep authored files intact, including a page that happens to use our default name.
        var suffix = 1
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = catalog.appendingPathComponent("VaporEndpoints-\(suffix).md")
            suffix += 1
        }
        try FileManager.default.copyItem(at: generatedPage, to: destination)
        return catalog
    }

    static func generate(executable: URL, module: String, sources: [String], symbolGraphDirectory: URL,
                         workingDirectory: URL, baseURL: String, warningsAsErrors: Bool = false, endpointsOnly: Bool = false) throws -> URL {
        try validate(baseURL: baseURL)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw VaporRouteExtractionError("Vapor route extractor is not executable: \(executable.path)")
        }
        // Replace only this target's private intermediate output, so removed routes cannot linger.
        if FileManager.default.fileExists(atPath: workingDirectory.path) {
            try FileManager.default.removeItem(at: workingDirectory)
        }
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let graphs = workingDirectory.appendingPathComponent("symbol-graphs", isDirectory: true)
        if endpointsOnly {
            try FileManager.default.createDirectory(at: graphs, withIntermediateDirectories: true)
        } else {
            try FileManager.default.copyItem(at: symbolGraphDirectory, to: graphs)
        }
        let output = graphs.appendingPathComponent("http", isDirectory: true)
        let request: [String: Any] = [
            "module": module, "sources": sources.sorted(),
            "symbolGraphDirectory": symbolGraphDirectory.path,
            "outputDirectory": output.path, "baseURL": baseURL, "warningsAsErrors": warningsAsErrors, "endpointsOnly": endpointsOnly,
        ]
        let requestFile = workingDirectory.appendingPathComponent("request.json")
        try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
            .write(to: requestFile, options: .atomic)
        let process = try Process.run(executable, arguments: [requestFile.path])
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw VaporRouteExtractionError("Vapor route extraction failed (exit \(process.terminationStatus)).")
        }
        guard FileManager.default.fileExists(atPath: output.appendingPathComponent("\(module).routes.symbols.json").path) else {
            throw VaporRouteExtractionError("Vapor route extractor did not produce the expected symbol graph.")
        }
        return graphs
    }
}
