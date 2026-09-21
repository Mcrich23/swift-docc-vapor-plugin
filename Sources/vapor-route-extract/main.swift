// This source file is part of the Swift.org open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for Swift project authors

import Foundation
import VaporRoutes

struct ExtractionRequest: Decodable {
    var module: String
    var sources: [String]
    var symbolGraphDirectory: String
    var outputDirectory: String
    var baseURL: String
    var endpointsOnly: Bool
    var warningsAsErrors: Bool
}

do {
    guard CommandLine.arguments.count == 2 else {
        throw ExtractionError("Usage: vapor-route-extract <request.json>")
    }
    let request = try JSONDecoder().decode(ExtractionRequest.self,
        from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
    guard let base = URLComponents(string: request.baseURL), ["http", "https"].contains(base.scheme),
          let host = base.host, !host.isEmpty, base.user == nil, base.password == nil, base.query == nil, base.fragment == nil else {
        throw ExtractionError("baseURL must be an absolute HTTP(S) URL without credentials, query, or fragment.")
    }
    var sources: [String: String] = [:]
    for file in request.sources.sorted() { sources[file] = try String(contentsOfFile: file, encoding: .utf8) }
    let extractor = RouteExtractor(sources: sources)
    var extraction = extractor.extract()
    let directory = URL(fileURLWithPath: request.symbolGraphDirectory, isDirectory: true)
    guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
        throw ExtractionError("Cannot read symbol graph directory: \(directory.path)")
    }
    let graphs = try files.compactMap { $0 as? URL }.filter { $0.lastPathComponent.hasSuffix(".symbols.json") }
        .sorted { $0.path < $1.path }.map { try Data(contentsOf: $0) }
    let graph = try HTTPGraph.generate(module: request.module, baseURL: request.baseURL,
                                      extraction: &extraction, swiftGraphs: graphs, endpointsOnly: request.endpointsOnly)
    for diagnostic in extraction.diagnostics {
        FileHandle.standardError.write(Data("\(diagnostic.file):\(diagnostic.line): warning: \(diagnostic.message)\n".utf8))
    }
    print("Extracted \(extraction.routes.count) HTTP endpoints (\(extraction.diagnostics.count) diagnostics).")
    if extraction.routes.isEmpty { throw ExtractionError("No HTTP endpoints extracted; see diagnostics.") }
    if request.warningsAsErrors && !extraction.diagnostics.isEmpty {
        throw ExtractionError("Route extraction produced warnings with --warnings-as-errors enabled.")
    }
    let output = URL(fileURLWithPath: request.outputDirectory, isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    if request.endpointsOnly {
        for (index, filtered) in try EndpointTypes.filter(module: request.module, referencedTypes: graph.referencedTypes, swiftGraphs: graphs).enumerated() {
            try filtered.write(to: output.appendingPathComponent("\(request.module).types-\(index).symbols.json"), options: .atomic)
        }
    }
    try graph.symbolGraph.write(to: output.appendingPathComponent("\(request.module).routes.symbols.json"), options: .atomic)
    try HTTPGraph.endpointCuration(module: request.module, routes: extraction.routes)
        .write(to: output.appendingPathComponent("VaporEndpoints.md"), atomically: true, encoding: .utf8)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(extraction).write(to: output.appendingPathComponent("routes-report.json"), options: .atomic)

} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
