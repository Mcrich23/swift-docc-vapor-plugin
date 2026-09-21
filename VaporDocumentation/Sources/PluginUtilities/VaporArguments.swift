// This source file is part of the Swift.org open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for Swift project authors

import Foundation

/// Vapor-specific arguments, leaving DocC options for the upstream parser.
struct VaporArguments {
    let baseURL: String?
    let endpointsOnly: Bool
    let warningsAsErrors: Bool
    let remainingArguments: [String]

    init(_ rawArguments: [String]) {
        var arguments = CommandLineArguments(rawArguments)
        endpointsOnly = arguments.extract(.init(preferred: "--vapor-endpoints-only")).last ?? false
        baseURL = arguments.extract(.init(preferred: "--vapor-routes", kind: .singleValue)).last
        remainingArguments = arguments.remainingArguments
        warningsAsErrors = arguments.extract(.init(preferred: "--warnings-as-errors")).last ?? false
    }

    func validated() throws -> VaporDocumentationOptions {
        guard let baseURL else {
            throw VaporRouteExtractionError(endpointsOnly
                ? "--vapor-endpoints-only requires --vapor-routes <base-url>."
                : "Vapor documentation requires --vapor-routes <base-url>.")
        }
        try VaporRouteDocumentation.validate(baseURL: baseURL)
        return VaporDocumentationOptions(baseURL: baseURL, endpointsOnly: endpointsOnly)
    }

    static func help(for action: PluginAction, docc: URL) throws -> String {
        let text = try HelpInformation.forAction(action, doccExecutableURL: docc)
            .replacingOccurrences(of: "generate-documentation", with: "generate-vapor-documentation")
            .replacingOccurrences(of: "preview-documentation", with: "preview-vapor-documentation")
        return text.replacingOccurrences(of: "PLUGIN OPTIONS:", with: """
        VAPOR OPTIONS:
          --vapor-routes <base-url>  The HTTP(S) service base URL (required).
          --vapor-endpoints-only    Include only endpoints and referenced local types.

        PLUGIN OPTIONS:
        """)
    }
}
