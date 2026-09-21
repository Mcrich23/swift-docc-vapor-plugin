// This source file is part of the Swift.org open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for Swift project authors

import Foundation
import XCTest
@testable import VaporDocumentationUtilities

final class VaporArgumentsTests: XCTestCase {
    func testVaporOptionsRequireAValidBaseURL() throws {
        for flags in [["--vapor-routes"], ["--vapor-routes="], ["--vapor-endpoints-only"], []] {
            let options = VaporArguments(flags)
            XCTAssertThrowsError(try options.validated())
        }
        let arguments = VaporArguments(["--vapor-routes=https://example.test", "--warnings-as-errors"])
        let options = try arguments.validated()
        XCTAssertEqual(options.baseURL, "https://example.test")
        XCTAssertFalse(options.endpointsOnly)
        XCTAssertTrue(arguments.warningsAsErrors)
        XCTAssertTrue(ParsedArguments(arguments.remainingArguments).doccArguments(action: .convert, targetKind: .executable,
            doccCatalogPath: nil, targetName: "App", symbolGraphDirectoryPath: "/graphs", outputPath: "/output")
            .contains("--warnings-as-errors"))
    }

    func testVaporExtractorArgumentsAreNotForwardedToDocC() throws {
        let arguments = VaporArguments([
            "--vapor-routes", "https://example.test", "--vapor-endpoints-only",
        ])
        let options = try arguments.validated()
        XCTAssertEqual(options.baseURL, "https://example.test")
        XCTAssertTrue(options.endpointsOnly)
        let forwarded = ParsedArguments(arguments.remainingArguments).doccArguments(action: .convert, targetKind: .executable,
            doccCatalogPath: nil, targetName: "App", symbolGraphDirectoryPath: "/graphs", outputPath: "/output")
        XCTAssertFalse(forwarded.contains { $0.contains("vapor") || $0.contains("example.test") })
    }

    func testHelpDescribesOnlyTheVaporCommands() throws {
        HelpInformation._doccHelp = { _, _ in nil }
        for action in [PluginAction.convert, .preview] {
            let help = try VaporArguments.help(for: action, docc: URL(fileURLWithPath: "/"))
            XCTAssertTrue(help.contains("--vapor-routes <base-url>"))
            XCTAssertTrue(help.contains(action == .convert ? "generate-vapor-documentation" : "preview-vapor-documentation"))
        }
    }

}
