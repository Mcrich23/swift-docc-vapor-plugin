// This source file is part of the Swift.org open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for Swift project authors

import Vapor

@main
struct Server {
    static func main() {
        // Documentation generation must never execute application code.
        fatalError("This fixture must not be run.")
    }
}

func routes(_ app: Application) throws {
    app.get("health") { _ in "OK" }
    try registerItems(app)
    try registerItems(app.grouped("admin", ":userID").grouped(AuditMiddleware()))
}

private func registerItems(_ routes: any RoutesBuilder) throws {
    try routes.register(collection: ItemController())
}

struct ItemController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let items = routes.grouped("items")
        // Assigned registrations must still be extracted.
        let _ = items.get(use: index).description("List available items.")
        items.group(":id") { item in
            item.get(use: detail)
        }
    }

    /// Lists the items in the catalog.
    ///
    /// - Parameter req: The request.
    /// - Returns: The available items.
    ///
    /// ## Pagination
    /// This example returns all items.
    func index(req: Request) -> [Item] { [] }
}

extension ItemController {
    /// Retrieves an item by identifier.
    func detail(req: Request) -> Item { Item(id: "example") }
}

/// A catalog item.
struct Item: Content {
    let id: String
}

struct AuditMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        try await next.respond(to: request)
    }
}
