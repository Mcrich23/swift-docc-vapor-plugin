// This source file is part of the Swift.org open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for Swift project authors

import Foundation
import PackagePlugin

/// Fork-owned inputs leave upstream's symbol graph result unchanged.
struct VaporDocumentationInputs {
    let unifiedSymbolGraphsDirectory: URL
    let targetSymbolGraphsDirectory: URL
    let generatedCatalogPath: String
}

extension PackageManager.DocCSymbolGraphResult {
    /// Add endpoint documentation to private inputs only when the Vapor command requested it.
    func addingVaporDocumentation(for target: SourceModuleTarget, context: PluginContext,
                                  options: VaporDocumentationOptions, warningsAsErrors: Bool) throws -> VaporDocumentationInputs {
        let executable = try context.tool(named: "vapor-route-extract")
        let workingDirectory = URL(fileURLWithPath: context.pluginWorkDirectory.string)
            .appendingPathComponent("vapor-routes/\(target.name)-\(target.id)", isDirectory: true)
        let directory = try VaporRouteDocumentation.generate(
            executable: URL(fileURLWithPath: executable.path.string), module: target.name,
            sources: target.sourceFiles(withSuffix: "swift").map { $0.path.string },
            symbolGraphDirectory: unifiedSymbolGraphsDirectory,
            workingDirectory: workingDirectory, baseURL: options.baseURL,
            warningsAsErrors: warningsAsErrors, endpointsOnly: options.endpointsOnly
        )
        let catalogPath = try VaporRouteDocumentation.catalog(
            original: options.endpointsOnly ? nil : target.doccCatalogPath.map { URL(fileURLWithPath: $0) },
            generatedPage: directory.appendingPathComponent("http/VaporEndpoints.md"),
            workingDirectory: workingDirectory
        ).path
        return VaporDocumentationInputs(unifiedSymbolGraphsDirectory: directory,
            targetSymbolGraphsDirectory: targetSymbolGraphsDirectory, generatedCatalogPath: catalogPath)
    }
}
