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

final class RouteExtractorTests: XCTestCase {
    func testUnsupportedHelperSignaturesDoNotInventRoutes() {
        let result = RouteExtractor(sources: ["Routes.swift": """
        func routes(_ app: Application) {
            register(app)
            app.get("visible") { _ in "OK" }
        }
        func register(_ value: String) {
            value.get("invented") { _ in "NO" }
        }
        """]).extract()
        XCTAssertEqual(result.routes.map(\.path), ["/visible"])
        XCTAssertTrue(result.diagnostics.contains { $0.message.contains("registration helper") })
    }

    func testActorMethodsAreNotTopLevelRegistrationEntries() {
        let result = RouteExtractor(sources: ["Routes.swift": """
        actor Worker {
            func routes(_ app: Application) { app.get("internal") { _ in "NO" } }
        }
        func routes(_ app: Application) { app.get("visible") { _ in "OK" } }
        """]).extract()
        XCTAssertEqual(result.routes.map(\.path), ["/visible"])
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    func testPathParameterDescriptionsMoveIntoNativeTableWithoutLosingBodyDocs() {
        var lines = ["Updates a collection.", "", "## Path Parameters", "", "- `collectionID`: The collection to update.",
                     "  More detail with ``App/Collection``.", "", "## Request Body", "A collection DTO."]
        let comments = HTTPGraph.extractPathParameterComments(from: &lines, names: ["collectionID", "impersonatedUserID"])
        XCTAssertEqual(comments["collectionID"], ["The collection to update.", "More detail with ``App/Collection``.", ""])
        XCTAssertNil(comments["impersonatedUserID"])
        XCTAssertEqual(lines, ["Updates a collection.", "", "## Request Body", "A collection DTO."])
    }

    func testUnrecognizedPathParameterDiscussionIsPreserved() {
        for body in [["An explanation in prose."], ["- `unknown`: An unrelated parameter."],
                     ["- `id`: First description.", "- `id`: Another description."]] {
            var lines = ["## Path Parameters"] + body + ["## Request Body", "Keep this."]
            XCTAssertTrue(HTTPGraph.extractPathParameterComments(from: &lines, names: ["id"]).isEmpty)
            XCTAssertEqual(lines, ["## Path Parameter Details"] + body + ["## Request Body", "Keep this."])
        }
        var example = ["```markdown", "## Path Parameters", "- `id`: Example only.", "```"]
        let original = example
        XCTAssertTrue(HTTPGraph.extractPathParameterComments(from: &example, names: ["id"]).isEmpty)
        XCTAssertEqual(example, original)
    }

    func testIgnoreDirectiveExcludesOnlyTheAnnotatedRegistrations() {
        let result = RouteExtractor(sources: ["Routes.swift": #"""
        func routes(_ app: Application) throws {
            // docc:ignore
            app.get { _ in "redirect" }
            // docc:ignore
            try app.grouped("admin").register(collection: Items())
            try app.register(collection: Items())
            // docc:ignore
            app.group("hidden") { $0.get("child") { _ in "hidden" } }
            // docc:ignore
            let hidden = app.grouped("internal")
            hidden.get("child") { _ in "hidden" }
            try registerMore(hidden)
            // docc:ignore
            let dynamic = app.grouped(makePrefix())
            dynamic.get("child") { _ in "hidden" }
            // docc:ignore
            app.get(computedPath) { _ in "hidden" }
            // docc:ignore
            let _ = app.get("assigned") { _ in "hidden" }
            app.get("visible") { _ in "// docc:ignore" }
            // Mentioning docc:ignore does not exclude a route.
            app.get("mentioned") { _ in "visible" }
        }
        struct Items: RouteCollection {
            func boot(routes: any RoutesBuilder) {
                routes.get("items") { _ in "visible" }
            }
        }
        func registerMore(_ routes: any RoutesBuilder) {
            routes.get("more") { _ in "hidden" }
        }
        """#]).extract()
        XCTAssertEqual(result.routes.map(\.path), ["/items", "/mentioned", "/visible"])
        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")
    }

    func testTrailingIgnoreCommentDoesNotExcludeNextRoute() {
        let result = RouteExtractor(sources: ["Routes.swift": """
        func routes(_ app: Application) {
            app.get("first") { _ in "OK" } // docc:ignore
            app.get("second") { _ in "OK" }
        }
        """]).extract()
        XCTAssertEqual(result.routes.map(\.path), ["/first", "/second"])
    }

    func testEndpointCurationGroupsByFirstPathComponentAndSortsWithinGroups() {
        let paths = ["/wallpapers/:id", "/me/profile", "/", "/wallpapers", "/admin/:userID/me", "/me", "/wallpapers-old"]
        let routes = paths.map {
            ExtractedRoute(method: "GET", path: $0, middleware: [], file: "Routes.swift", line: 1)
        }
        let page = HTTPGraph.endpointCuration(module: "App", routes: routes)
        XCTAssertEqual(page, HTTPGraph.endpointCuration(module: "App", routes: routes.reversed()))
        XCTAssertEqual(page.components(separatedBy: "\n").filter { $0.hasPrefix("### ") },
                       ["### /", "### /admin", "### /me", "### /wallpapers", "### /wallpapers-old"])
        XCTAssertTrue(page.contains("### /me\n\n- ``App/HTTP-GET-_2Fme``\n- ``App/HTTP-GET-_2Fme_2Fprofile``"))
        XCTAssertTrue(page.contains("### /wallpapers\n\n- ``App/HTTP-GET-_2Fwallpapers``\n- ``App/HTTP-GET-_2Fwallpapers_2F_3Aid``"))
        XCTAssertEqual(page.components(separatedBy: "\n").filter { $0.hasPrefix("- ``") }.count, paths.count)
    }

    func testAssignedRegistrationDescriptionsAndLiteralCaptures() {
        let result = RouteExtractor(sources: ["Routes.swift": #"""
        func routes(_ app: Application) {
            let _ = app.grouped("api").get("{literal}", ":id") { _ in "OK" }
                .description("Fetch an item.")
            app.get("caf\u{e9}") { _ in "OK" }
        }
        """#]).extract()
        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")
        XCTAssertEqual(result.routes.map(\.path), ["/api/{literal}/:id", "/café"])
        XCTAssertEqual(result.routes.first?.pathParameters, ["id"])
        XCTAssertEqual(result.routes.first?.summary, "Fetch an item.")
    }

    func testCopiedDocumentationPreservesDiscussionAndSymbolScope() {
        let lines = HTTPGraph.endpointComments([
            "GET /items Fetches an item.", "", "- Parameter req: The request.",
            "  Additional parameter detail.", "", "- Returns: An item.", "", "## Pagination", "More discussion.",
        ])
        XCTAssertEqual(lines, ["Fetches an item.", "", "", "## Return Value", "", "An item.", "", "## Pagination", "More discussion."])
        XCTAssertEqual(HTTPGraph.qualifyLinks("Uses ``Item`` and ``Unknown``.", scope: ["Controller"],
            module: "App", paths: ["Controller/Item", "Item"]), "Uses ``App/Controller/Item`` and ``Unknown``.")
    }

    func testMissingModuleGraphFails() {
        var extraction = RouteExtraction()
        XCTAssertThrowsError(try HTTPGraph.generate(module: "Missing", baseURL: "https://example.test",
            extraction: &extraction, swiftGraphs: []))
    }

    func testNestedGroupsAndReusedCollections() throws {
        let source = """
        struct Authenticator: AsyncBearerAuthenticator {}
        func routes(_ app: Application) throws {
            try registerUserRoutes(app)
            let admin = app.grouped("admin", ":userID").grouped(Authenticator(), User.guardMiddleware())
            try registerUserRoutes(admin)
        }
        private func registerUserRoutes(_ routes: any RoutesBuilder) throws {
            try routes.register(collection: Wallpapers())
        }
        struct Wallpapers: RouteCollection {
            func boot(routes: any RoutesBuilder) throws {
                let wallpapers = routes.grouped("wallpapers")
                wallpapers.get(use: index)
                wallpapers.group(":id") { item in
                    item.get(use: self.get)
                    item.group("images") { $0.on(.POST, body: .collect(maxSize: "20mb"), use: create) }
                }
            }
            func index(req: Request) async throws -> Page<WallpaperDTO> { fatalError() }
            func get(req: Request) async throws -> WallpaperDTO { fatalError() }
            func create(req: Request) async throws -> WallpaperDTO { fatalError() }
        }
        """
        let result = RouteExtractor(sources: ["Routes.swift": source]).extract()
        XCTAssertEqual(result.routes.count, 6)
        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")
        let route = try XCTUnwrap(result.routes.first { $0.path == "/admin/:userID/wallpapers/:id/images" })
        XCTAssertEqual(route.method, "POST")
        XCTAssertEqual(route.handler, "Wallpapers.create")
        XCTAssertEqual(route.middleware, ["Authenticator()", "User.guardMiddleware()"])
        XCTAssertTrue(result.routes.first { $0.path == "/wallpapers" }!.middleware.isEmpty)
    }

    func testDynamicPathsAndControlFlowAreNotInvented() {
        let source = #"""
        func routes(_ app: Application) throws {
            app.get("literal", use: handler)
            app.get(prefix, use: handler)
            app.get("users/\(id)", use: handler)
            let dynamic = app.grouped(prefix)
            dynamic.get("nope", use: handler)
            if enabled { app.get("conditional", use: handler) }
            for name in names { app.get(name, use: handler) }
        }
        func handler(req: Request) -> String { "OK" }
        """#
        let result = RouteExtractor(sources: ["Routes.swift": source]).extract()
        XCTAssertEqual(result.routes.map(\.path), ["/literal"])
        XCTAssertTrue(result.diagnostics.contains { $0.message.contains("dynamic route path") })
        XCTAssertTrue(result.diagnostics.contains { $0.message.contains("conditional") })
    }

    func testDuplicateEndpointsAreOmittedAndOverloadsAreNotGuessed() {
        let result = RouteExtractor(sources: ["Routes.swift": """
        func routes(_ app: Application) {
            app.get("same", use: first)
            app.get("same", use: second)
            app.get("overload", use: overloaded)
        }
        func first(req: Request) -> String { "first" }
        func second(req: Request) -> String { "second" }
        func overloaded(req: Request) -> String { "one" }
        func overloaded(req: OtherRequest) -> String { "two" }
        """]).extract()
        XCTAssertEqual(result.routes.map(\.path), ["/overload"])
        XCTAssertNil(result.routes.first?.handler)
        XCTAssertTrue(result.diagnostics.contains { $0.message.contains("Duplicate") })
        XCTAssertTrue(result.diagnostics.contains { $0.message.contains("overloaded") })
    }

    func testRecursionIsBoundedAndInlineEndpointsSurvive() {
        let result = RouteExtractor(sources: ["Routes.swift": """
        func routes(_ app: Application) throws {
            app.get("version") { _ in "v1" }
            try recurse(app)
        }
        func recurse(_ routes: any RoutesBuilder) throws { try recurse(routes) }
        """]).extract()
        XCTAssertEqual(result.routes.map(\.path), ["/version"])
        XCTAssertTrue(result.diagnostics.contains { $0.message.contains("Recursive") })
    }

    func testNoEntryPointProducesDiagnostic() {
        let result = RouteExtractor(sources: ["Other.swift": "func unrelated() {} "]).extract()
        XCTAssertTrue(result.routes.isEmpty)
        XCTAssertEqual(result.diagnostics.count, 1)
    }

    func testPathFactoryIsNotMistakenForMiddleware() {
        let result = RouteExtractor(sources: ["Routes.swift": """
        func routes(_ app: Application) {
            let dynamic = app.grouped(makePrefix())
            dynamic.get("wrong") { _ in "no" }
            app.get("right") { _ in "yes" }
        }
        """]).extract()
        XCTAssertEqual(result.routes.map(\.path), ["/right"])
        XCTAssertTrue(result.diagnostics.contains { $0.message.contains("dynamic group") })
    }

    func testConditionalDeclarationsAreNotAssumedActive() {
        let result = RouteExtractor(sources: ["Routes.swift": """
        #if FEATURE
        func routes(_ app: Application) { app.get("conditional") { _ in "yes" } }
        #endif
        """]).extract()
        XCTAssertTrue(result.routes.isEmpty)
        XCTAssertTrue(result.diagnostics.contains { $0.message.contains("Conditional compilation") })
    }

    func testMalformedSourceIsDiagnosed() {
        let result = RouteExtractor(sources: ["Routes.swift": "func routes(_ app: Application) { app.get("]).extract()
        XCTAssertTrue(result.routes.isEmpty)
        XCTAssertTrue(result.diagnostics.contains { $0.message.contains("syntax errors") })
    }

    func testHTTPGraphLinksHandlerAndTypesWithoutInventingResponses() throws {
        var extraction = RouteExtraction(routes: [
            .init(method: "GET", path: "/admin/:userID/wallpapers", handler: "Wallpapers.index",
                  middleware: ["Authenticator()"], file: "/tmp/Routes.swift", line: 4, pathParameters: ["userID"]),
        ])
        let swiftGraph: [String: Any] = [
            "metadata": ["formatVersion": ["major": 0, "minor": 6, "patch": 0], "generator": "test"],
            "module": ["name": "App", "platform": [:]],
            "relationships": [],
            "symbols": [
                ["identifier": ["precise": "s:index", "interfaceLanguage": "swift"], "kind": ["identifier": "swift.method", "displayName": "Method"],
                 "names": ["title": "index(req:)"], "accessLevel": "internal",
                 "pathComponents": ["Wallpapers", "index(req:)"],
                 "docComment": ["lines": [["text": "GET /wallpapers Lists wallpapers."], ["text": ""],
                                          ["text": "## Path Parameters"], ["text": "- `userID`: The selected user."],
                                          ["text": "## Discussion"],
                                          ["text": ""], ["text": "- Parameters:"], ["text": "  - req: Request"]]],
                 "functionSignature": ["returns": [["kind": "typeIdentifier", "spelling": "WallpaperDTO", "preciseIdentifier": "s:dto"]]]],
                ["identifier": ["precise": "s:dto", "interfaceLanguage": "swift"], "kind": ["identifier": "swift.struct", "displayName": "Structure"],
                 "names": ["title": "WallpaperDTO"], "accessLevel": "internal", "pathComponents": ["WallpaperDTO"]],
            ],
        ]
        let data = try HTTPGraph.generate(module: "App", baseURL: "https://example.test", extraction: &extraction,
            swiftGraphs: [JSONSerialization.data(withJSONObject: swiftGraph)])
        XCTAssertEqual(data.referencedTypes, ["s:dto"])
        let graph = try XCTUnwrap(JSONSerialization.jsonObject(with: data.symbolGraph) as? [String: Any])
        let symbols = try XCTUnwrap(graph["symbols"] as? [[String: Any]])
        XCTAssertEqual(symbols.count, 2)
        let endpoint = symbols[0]
        XCTAssertEqual((endpoint["identifier"] as? [String: String])?["interfaceLanguage"], "swift")
        XCTAssertEqual((endpoint["httpEndpoint"] as? [String: String])?["path"], "/admin/:userID/wallpapers")
        let comments = try XCTUnwrap((endpoint["docComment"] as? [String: Any])?["lines"] as? [[String: String]])
        let text = comments.compactMap { $0["text"] }.joined(separator: "\n")
        XCTAssertTrue(text.hasPrefix("Lists wallpapers."))
        XCTAssertTrue(text.contains("``App/Wallpapers/index(req:)``"))
        XCTAssertTrue(text.contains("``App/WallpaperDTO``"))
        XCTAssertTrue(text.contains("## Swift Return Type\n\n``App/WallpaperDTO``"))
        XCTAssertFalse(text.contains("`WallpaperDTO`"))
        XCTAssertFalse(text.contains("- ``App/WallpaperDTO``"))
        XCTAssertFalse(text.contains("- Parameters:"))
        XCTAssertFalse(text.contains("## Path Parameters"))
        XCTAssertTrue(text.contains("- HTTPParameter userID: The selected user."))
        XCTAssertTrue(extraction.diagnostics.isEmpty)
        XCTAssertFalse(symbols.contains { ($0["kind"] as? [String: String])?["identifier"] == "httpResponse" })

        let focused = try HTTPGraph.generate(module: "App", baseURL: "https://example.test", extraction: &extraction,
            swiftGraphs: [JSONSerialization.data(withJSONObject: swiftGraph)], endpointsOnly: true)
        XCTAssertEqual(focused.referencedTypes, data.referencedTypes)
        XCTAssertFalse(String(decoding: focused.symbolGraph, as: UTF8.self).contains("Swift Handler"))

        var nestedGraph = swiftGraph
        var nestedSymbols = try XCTUnwrap(nestedGraph["symbols"] as? [[String: Any]])
        nestedSymbols[0]["functionSignature"] = ["returns": [
            ["kind": "typeIdentifier", "spelling": "Wallpapers"],
            ["kind": "text", "spelling": "."],
            ["kind": "typeIdentifier", "spelling": "WallpaperDTO", "preciseIdentifier": "s:dto"],
        ]]
        nestedSymbols[1]["pathComponents"] = ["Wallpapers", "WallpaperDTO"]
        nestedGraph["symbols"] = nestedSymbols
        let nestedData = try HTTPGraph.generate(module: "App", baseURL: "https://example.test", extraction: &extraction,
            swiftGraphs: [JSONSerialization.data(withJSONObject: nestedGraph)])
        let nestedOutput = try XCTUnwrap(JSONSerialization.jsonObject(with: nestedData.symbolGraph) as? [String: Any])
        let nestedEndpoint = try XCTUnwrap((nestedOutput["symbols"] as? [[String: Any]])?.first)
        let nestedLines = try XCTUnwrap((nestedEndpoint["docComment"] as? [String: Any])?["lines"] as? [[String: String]])
        let nestedText = nestedLines.compactMap { $0["text"] }.joined(separator: "\n")
        XCTAssertTrue(nestedText.contains("## Swift Return Type\n\n``App/Wallpapers/WallpaperDTO``"))
        XCTAssertFalse(nestedText.contains("`Wallpapers.WallpaperDTO`"))
        XCTAssertFalse(nestedText.contains("- ``App/Wallpapers/WallpaperDTO``"))
    }
}
