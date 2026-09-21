// This source file is part of the Swift.org open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for Swift project authors

import Foundation
import SwiftParser
import SwiftSyntax

public struct ExtractedRoute: Codable, Equatable {
    public var method: String
    public var path: String
    public var handler: String?
    public var middleware: [String]
    public var file: String
    public var line: Int
    public var pathParameters: [String] = []
    public var summary: String?
}

public struct RouteDiagnostic: Codable, Equatable {
    public var file: String
    public var line: Int
    public var message: String
}

public struct RouteExtraction: Codable {
    public var routes: [ExtractedRoute] = []
    public var diagnostics: [RouteDiagnostic] = []
}

/// A deliberately bounded interpreter for route *registration syntax*. Never runs application code.
/// Unsupported control flow or dynamic paths are diagnosed instead of guessed.
public final class RouteExtractor {
    struct Function {
        var declaration: FunctionDeclSyntax
        var owner: String?
        var file: String
        var converter: SourceLocationConverter

        var acceptsRouteBuilder: Bool {
            let parameters = declaration.signature.parameterClause.parameters
            guard parameters.count == 1, let parameter = parameters.first else { return false }
            return ["RoutesBuilder", "any RoutesBuilder", "Vapor.RoutesBuilder", "any Vapor.RoutesBuilder",
                    "Application", "Vapor.Application"].contains(parameter.type.trimmedDescription)
        }

        var key: String { [owner, declaration.name.text].compactMap { $0 }.joined(separator: ".") }
    }

    private struct Builder {
        var isExcluded = false
        var path: [String] = []
        var middleware: [String] = []
    }

    private var functions: [String: [Function]] = [:]
    private var middlewareTypes: Set<String> = ["ErrorMiddleware", "FileMiddleware", "CORSMiddleware"]
    private var sourceDiagnostics: [RouteDiagnostic] = []
    private var activeFunctions: Set<String> = []
    private var result = RouteExtraction()

    public init(sources: [String: String]) {
        for (file, source) in sources.sorted(by: { $0.key < $1.key }) {
            let tree = Parser.parse(source: source)
            guard !tree.hasError else {
                sourceDiagnostics.append(.init(file: file, line: 1,
                    message: "Source contains syntax errors; this file was not analyzed."))
                continue
            }
            let collector = FunctionCollector(file: file, tree: tree)
            collector.walk(tree)
            sourceDiagnostics += collector.diagnostics
            middlewareTypes.formUnion(collector.middlewareTypes)
            for function in collector.functions {
                functions[function.key, default: []].append(function)
            }
        }
    }

    /// Starts at a unique top-level `routes(_ app: Application)` function.
    public func extract() -> RouteExtraction {
        result = RouteExtraction(diagnostics: sourceDiagnostics)
        guard let entries = functions["routes"], entries.count == 1,
              let entry = entries.first,
              entry.declaration.signature.parameterClause.parameters.count == 1,
              ["Application", "Vapor.Application"].contains(entry.declaration.signature.parameterClause.parameters.first?.type.trimmedDescription)
        else {
            result.diagnostics.append(.init(file: "", line: 1,
                message: "Expected one top-level routes(_ app: Application) entry point; no routes extracted."))
            return result
        }
        invoke(entry, builder: Builder())
        let grouped = Dictionary(grouping: result.routes, by: { "\($0.method) \($0.path)" })
        for (key, routes) in grouped where routes.count > 1 {
            result.diagnostics.append(.init(file: routes[0].file, line: routes[0].line,
                message: "Duplicate registration for \(key); omitted because its handler is ambiguous."))
        }
        result.routes = result.routes.filter { grouped["\($0.method) \($0.path)"]?.count == 1 }
            .sorted { ($0.path, $0.method) < ($1.path, $1.method) }
        result.diagnostics.sort { ($0.file, $0.line, $0.message) < ($1.file, $1.line, $1.message) }
        return result
    }

    private func warn(_ node: some SyntaxProtocol, _ function: Function, _ message: String) {
        let diagnostic = RouteDiagnostic(file: function.file,
            line: node.startLocation(converter: function.converter).line, message: message)
        if !result.diagnostics.contains(diagnostic) { result.diagnostics.append(diagnostic) }
    }

    private func invoke(_ function: Function, builder: Builder) {
        guard !builder.isExcluded else { return }
        guard activeFunctions.insert(function.key).inserted else {
            warn(function.declaration, function, "Recursive registration helper \(function.key) was skipped.")
            return
        }
        defer { activeFunctions.remove(function.key) }
        guard let parameter = function.declaration.signature.parameterClause.parameters.first,
              let body = function.declaration.body else { return }
        let name = (parameter.secondName ?? parameter.firstName).text
        evaluate(body.statements, environment: [name: builder], function: function)
    }

    private func evaluate(_ statements: CodeBlockItemListSyntax, environment initial: [String: Builder], function: Function) {
        var environment = initial
        for statement in statements {
            let excluded = statement.leadingTrivia.contains { piece in
                if case .lineComment(let text) = piece {
                    return text.trimmingCharacters(in: .whitespaces) == "// docc:ignore"
                }
                return false
            }
            if let variable = statement.item.as(VariableDeclSyntax.self) {
                for binding in variable.bindings {
                    guard let expression = binding.initializer?.value else { continue }
                    let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
                    if excluded {
                        if let name { environment[name] = Builder(isExcluded: true) }
                        continue
                    }
                    if let builder = resolveBuilder(expression, environment, function) {
                        if let name { environment[name] = builder }
                    } else {
                        if let name { environment[name] = nil }
                        // Registering a route still has an effect when its result is assigned.
                        if let call = unwrap(expression).as(FunctionCallExprSyntax.self) {
                            evaluate(call, environment: environment, function: function)
                        }
                    }
                }
            } else if excluded {
                continue
            } else if let expression = statement.item.as(ExprSyntax.self),
                      let call = unwrap(expression).as(FunctionCallExprSyntax.self) {
                evaluate(call, environment: environment, function: function)
            } else {
                // Do not walk into branches/loops: doing so would invent routes from inactive paths.
                warn(statement, function, "Unsupported registration statement; conditional or computed registrations require explicit support.")
                // Later statements could depend on assignments in this unsupported statement.
                return
            }
        }
    }

    private func resolveBuilder(_ expression: ExprSyntax, _ environment: [String: Builder], _ function: Function) -> Builder? {
        let expression = unwrap(expression)
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            return environment[reference.baseName.text]
        }
        guard let call = expression.as(FunctionCallExprSyntax.self),
              let member = call.calledExpression.as(MemberAccessExprSyntax.self),
              member.declName.baseName.text == "grouped", let base = member.base,
              let builder = resolveBuilder(base, environment, function) else { return nil }
        return extend(builder, with: call.arguments, function: function)
    }

    private func extend(_ original: Builder, with arguments: LabeledExprListSyntax, function: Function) -> Builder? {
        var builder = original
        let values = arguments.filter { $0.label == nil }
        // Vapor overloads grouped/group for paths and middleware. Mixing the two isn't supported.
        if values.allSatisfy({ literal($0.expression) != nil }) {
            builder.path += values.compactMap { literal($0.expression) }
        } else if values.allSatisfy({ isMiddleware($0.expression) }) {
            builder.middleware += values.map { $0.expression.trimmedDescription }
        } else {
            warn(arguments, function, "Cannot resolve a dynamic group path or middleware value; this group was skipped.")
            return nil
        }
        return builder
    }

    private func isMiddleware(_ expression: ExprSyntax) -> Bool {
        guard let call = expression.as(FunctionCallExprSyntax.self) else { return false }
        if let type = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            return middlewareTypes.contains(type.baseName.text)
        }
        // Vapor's Authenticatable.guardMiddleware() factory doesn't add a path component.
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
            return member.declName.baseName.text == "guardMiddleware" && call.arguments.isEmpty
        }
        return false
    }

    private func evaluate(_ call: FunctionCallExprSyntax, environment: [String: Builder], function: Function) {
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self),
           member.declName.baseName.text == "description",
           let base = member.base?.as(FunctionCallExprSyntax.self) {
            let before = result.routes.count
            evaluate(base, environment: environment, function: function)
            if result.routes.count == before + 1, call.arguments.count == 1,
               let argument = call.arguments.first, let summary = literal(argument.expression) {
                result.routes[before].summary = summary
            } else {
                warn(call, function, "Cannot resolve this route description; use a string literal on a route registration.")
            }
            return
        }
        // Application-wide middleware does not change the route table. Its policy isn't inferred.
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self), member.declName.baseName.text == "use",
           let middleware = member.base?.as(MemberAccessExprSyntax.self), middleware.declName.baseName.text == "middleware",
           let base = middleware.base, resolveBuilder(base, environment, function) != nil {
            return
        }
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self), let base = member.base,
           let builder = resolveBuilder(base, environment, function) {
            guard !builder.isExcluded else { return }
            let name = member.declName.baseName.text
            if name == "register" {
                guard let argument = call.arguments.first(where: { $0.label?.text == "collection" }),
                      let constructor = argument.expression.as(FunctionCallExprSyntax.self),
                      let type = constructor.calledExpression.as(DeclReferenceExprSyntax.self),
                      constructor.arguments.isEmpty,
                      let boots = functions[type.baseName.text + ".boot"], boots.count == 1, boots[0].acceptsRouteBuilder else {
                    warn(call, function, "Cannot resolve this route collection; registration was skipped.")
                    return
                }
                invoke(boots[0], builder: builder)
            } else if name == "group" {
                guard let closure = call.trailingClosure else {
                    warn(call, function, "A route group requires a trailing closure; registration was skipped.")
                    return
                }
                guard let grouped = extend(builder, with: call.arguments, function: function) else { return }
                var scoped = environment
                scoped[closureParameter(closure)] = grouped
                evaluate(closure.statements, environment: scoped, function: function)
            } else if Self.methods.contains(name.uppercased()) || name == "on" {
                var arguments = Array(call.arguments)
                let method: String
                if name == "on" {
                    guard let first = arguments.first,
                          let value = first.expression.as(MemberAccessExprSyntax.self), value.base == nil,
                          Self.methods.contains(value.declName.baseName.text) else {
                        warn(call, function, "Cannot resolve a computed HTTP method; route was skipped.")
                        return
                    }
                    method = value.declName.baseName.text
                    arguments.removeFirst()
                } else { method = name.uppercased() }
                let pathArguments = arguments.filter { $0.label == nil }
                guard pathArguments.allSatisfy({ literal($0.expression) != nil }) else {
                    warn(call, function, "Cannot resolve a dynamic route path; route was skipped.")
                    return
                }
                let components = builder.path + pathArguments.compactMap { literal($0.expression) }
                let path = "/" + components.joined(separator: "/")
                var handler: String?
                if let use = arguments.first(where: { $0.label?.text == "use" }) {
                    let name: String?
                    if let reference = use.expression.as(DeclReferenceExprSyntax.self) {
                        name = reference.baseName.text
                    } else if let reference = use.expression.as(MemberAccessExprSyntax.self), reference.base?.trimmedDescription == "self" {
                        name = reference.declName.baseName.text
                    } else { name = nil }
                    if let name {
                        let key = [function.owner, name].compactMap { $0 }.joined(separator: ".")
                        if functions[key]?.count == 1 { handler = key }
                    }
                }
                if handler == nil && call.trailingClosure == nil && !arguments.contains(where: { $0.expression.is(ClosureExprSyntax.self) }) {
                    warn(call, function, "\(method) \(path): handler is overloaded or unresolved; only the endpoint is documented.")
                }
                result.routes.append(.init(method: method, path: path, handler: handler,
                    middleware: builder.middleware, file: function.file,
                    line: call.startLocation(converter: function.converter).line,
                    pathParameters: components.filter { $0.hasPrefix(":") }.map { String($0.dropFirst()) }))
            } else {
                warn(call, function, "Unsupported route-builder operation '\(name)'; registration was skipped.")
            }
        } else if let name = call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text,
                  let first = call.arguments.first,
                  let builder = resolveBuilder(first.expression, environment, function) {
            guard call.arguments.count == 1, let helpers = functions[name], helpers.count == 1, helpers[0].acceptsRouteBuilder else {
                warn(call, function, "Cannot resolve registration helper '\(name)'; registration was skipped.")
                return
            }
            invoke(helpers[0], builder: builder)
        } else {
            // Known non-registration setup may remain in routes(_:), but unknown calls aren't silently ignored.
            warn(call, function, "Unresolved call in registration function; verify whether it registers routes: \(call.calledExpression.trimmedDescription)")
        }
    }

    private static let methods: Set<String> = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS", "CONNECT", "TRACE"]

    private func literal(_ expression: ExprSyntax) -> String? {
        expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue
    }

    private func unwrap(_ expression: ExprSyntax) -> ExprSyntax {
        if let value = expression.as(TryExprSyntax.self) { return unwrap(value.expression) }
        if let value = expression.as(AwaitExprSyntax.self) { return unwrap(value.expression) }
        return expression
    }

    private func closureParameter(_ closure: ClosureExprSyntax) -> String {
        guard let parameters = closure.signature?.parameterClause else { return "$0" }
        switch parameters {
        case .simpleInput(let parameters): return parameters.first?.name.text ?? "$0"
        case .parameterClause(let parameters): return parameters.parameters.first?.firstName.text ?? "$0"
        }
    }
}

private final class FunctionCollector: SyntaxVisitor {
    var functions: [RouteExtractor.Function] = []
    var middlewareTypes: Set<String> = []
    var diagnostics: [RouteDiagnostic] = []
    private var owners: [String] = []
    private let file: String
    private let converter: SourceLocationConverter

    init(file: String, tree: SourceFileSyntax) {
        self.file = file
        self.converter = SourceLocationConverter(fileName: file, tree: tree)
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        collectMiddleware(name: node.name.text, inheritance: node.inheritanceClause)
        owners.append(node.name.text)
        return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { owners.removeLast() }
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        collectMiddleware(name: node.name.text, inheritance: node.inheritanceClause)
        owners.append(node.name.text)
        return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { owners.removeLast() }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        owners.append(node.name.text)
        return .visitChildren
    }
    override func visitPost(_ node: ActorDeclSyntax) { owners.removeLast() }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        owners.append(node.name.text)
        return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) { owners.removeLast() }
    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        collectMiddleware(name: node.extendedType.trimmedDescription, inheritance: node.inheritanceClause)
        owners.append(node.extendedType.trimmedDescription)
        return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { owners.removeLast() }
    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: IfConfigDeclSyntax) -> SyntaxVisitorContinueKind {
        diagnostics.append(.init(file: file, line: node.startLocation(converter: converter).line,
            message: "Conditional compilation was not evaluated; declarations in this block were skipped."))
        return .skipChildren
    }
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        functions.append(.init(declaration: node, owner: owners.isEmpty ? nil : owners.joined(separator: "."),
            file: file, converter: converter))
        return .skipChildren
    }

    private func collectMiddleware(name: String, inheritance: InheritanceClauseSyntax?) {
        let protocols: Set<String> = ["Middleware", "AsyncMiddleware", "Authenticator", "AsyncAuthenticator",
            "BearerAuthenticator", "AsyncBearerAuthenticator", "BasicAuthenticator", "AsyncBasicAuthenticator",
            "SessionAuthenticator", "AsyncSessionAuthenticator"]
        if inheritance?.inheritedTypes.contains(where: { protocols.contains($0.type.trimmedDescription) }) == true {
            middlewareTypes.insert(name)
        }
    }
}
