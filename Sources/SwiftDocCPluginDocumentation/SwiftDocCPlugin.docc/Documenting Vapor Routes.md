# Documenting Vapor Routes

Include HTTP endpoints alongside your Vapor application's Swift documentation.

## Overview

Pass `--vapor-routes` with your service's base URL to generate endpoint documentation:

```shell
swift package generate-vapor-documentation --target Server --vapor-routes https://api.example.com
```

Use `preview-vapor-documentation` with the same options for a live preview. Route extraction requires Swift 5.9 or later.
SwiftPM builds the extractor automatically; no additional executable or route annotations are needed.
The Vapor commands build the SwiftSyntax extractor on first use and reuse SwiftPM's cached tools
afterward. Ordinary `generate-documentation` and `preview-documentation` commands keep their existing
tool dependencies and do not build the extractor. SwiftPM still resolves SwiftSyntax as a package
dependency on Swift 5.9 or later.
For a library target with internal handlers, also pass `--symbol-graph-minimum-access-level internal`.
Executable targets already include internal declarations by default.

The plugin reads route registrations in the selected target, starting at its top-level
`routes(_ app: Application)` function. It follows literal path groups, local registration helpers,
and route collections to determine each endpoint's HTTP method and full path. For example:

```swift
func routes(_ app: Application) throws {
    try app.grouped("api", "v1").register(collection: ItemController())
}

struct ItemController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.get("items", ":id", use: show)
    }

    /// Fetches an item by its identifier.
    func show(req: Request) async throws -> Item {
        // ...
    }
}
```

This produces `GET /api/v1/items/:id` in the module's **Endpoints** collection and sidebar.
Endpoints are grouped by their first path component, such as `/api`, `/me`, or `/wallpapers`,
and ordered by path and HTTP method within each group. The root route has its own `/` group.
Its page includes the base URL, path captures, the handler's documentation, and links to the
Swift handler and local return types. Reusing a controller under another group creates pages
for those additional paths, using the same handler documentation. Inline handlers also produce
endpoint pages. Vapor's `.description("...")` supplies an optional endpoint summary.

Route extraction reads source and compiler symbol graphs; it does not start the application,
connect to a database, or execute registration code.

## Generating Only Endpoint Documentation

Add `--vapor-endpoints-only` to generate a focused API reference:

```shell
swift package generate-vapor-documentation --target Server --vapor-routes https://api.example.com --vapor-endpoints-only
```

This mode includes endpoints and local types referenced by their return signatures or symbol links
in handler documentation. For example, link a request body type with double backticks in the handler's
documentation to include it. The plugin follows type references transitively and includes properties,
enum cases, and associated types. Nested types are included when referenced. It does not inspect handler implementations to infer
request body types. Types must be present in the selected target's compiler symbol graphs.

Swift handler pages and unrelated symbols are omitted. A nested type may retain a minimal parent
page to preserve its qualified path, without including that parent's unrelated members. This mode
uses the generated Endpoints catalog rather than the target's authored documentation catalog, so
unrelated articles and documentation extensions are not included. Without this flag, generation
continues to include the full Swift documentation and authored catalog.

The option also works with `preview-vapor-documentation` and requires `--vapor-routes`.

## Supported Registrations

The extractor follows these patterns within the selected target:

- Literal paths passed to HTTP verb methods such as `get` and `post`, or `on(.POST, ...)`.
- `grouped` and `group` path prefixes, including nested groups and `:parameter` captures.
- Locally declared middleware constructors, common Vapor middleware, and `guardMiddleware()` groups.
- No-argument route collection construction, such as `register(collection: ItemController())`.
- Top-level helper functions accepting a single route builder, and handlers declared in controller extensions.
- Unambiguous named handlers, inline closures, and literal route descriptions.

The extractor does not evaluate computed paths, runtime configuration, branches, loops, or conditional
compilation. It diagnoses unsupported registrations instead of guessing. A control-flow statement
ends analysis of that registration block because subsequent registrations might depend on it.
Declarations in dependencies and other targets are not analyzed. Overloaded or otherwise unresolved
handlers retain endpoint pages when their method and path are known, with a diagnostic for the missing
handler documentation. Duplicate method/path registrations are diagnosed and omitted.

Review extraction warnings when adding routes. Pass `--warnings-as-errors` to require both route
extraction and DocC conversion to succeed without warnings. An invalid base URL, failed extractor,
or an empty route table fails documentation generation.

## Excluding Routes

Place `// docc:ignore` on its own line before a registration to omit it from endpoint documentation:

```swift
// docc:ignore
app.get { req in
    req.redirect(to: "https://example.com")
}

// docc:ignore
try app.grouped("admin").register(collection: AdminController())
```

The directive applies to the following statement. Ignoring a group, collection mount, or helper call
excludes its routes, while other mounts of the same controller remain documented. An ignored
`let hidden = app.grouped("internal")` also excludes registrations made through that builder.
Use the exact standalone comment; trailing comments and mentions in prose do not apply.
This affects generated endpoint pages only, not runtime routing or Swift symbol visibility.

## HTTP and Swift Types

Swift return types describe the handler's API, not a complete HTTP response schema. The plugin does
not infer status codes, content types, query parameters, request bodies, or authentication requirements
from Swift signatures or middleware names. Document these details in the handler's prose. Path captures
are shown as strings; conversions and validation performed inside a handler aren't inferred.

<!-- Copyright (c) 2026 Apple Inc and the Swift Project authors. All Rights Reserved. -->
