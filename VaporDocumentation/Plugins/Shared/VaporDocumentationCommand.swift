// This source file is part of the Swift.org open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for Swift project authors

#if os(Windows)
import WinSDK
#elseif canImport(Android)
import Android
#endif
import Foundation
import PackagePlugin

extension CommandPlugin {
    func runVaporDocumentation(_ action: PluginAction, context: PluginContext, arguments: [String]) throws {
        let docc = try context.doccExecutable
        var extractor = ArgumentExtractor(arguments)
        let specifiedTargets = try extractor.extractSpecifiedTargets(in: context.package)
        let vaporArguments = VaporArguments(extractor.remainingArguments)
        let parsed = ParsedArguments(vaporArguments.remainingArguments)

        if parsed.pluginArguments.help {
            print(try VaporArguments.help(for: action, docc: docc))
            return
        }

        let options = try vaporArguments.validated()
        let targets = specifiedTargets.isEmpty
            ? (action == .preview ? context.package.topLevelDocumentableTargets : context.package.allDocumentableTargets)
            : specifiedTargets
        guard !targets.isEmpty else { throw ArgumentParsingError.packageDoesNotContainSourceModuleTargets }
        if action == .preview && targets.count != 1 {
            throw VaporRouteExtractionError("Preview requires exactly one documentable target; specify --target.")
        }

        let verbose = parsed.pluginArguments.verbose
        let combined = parsed.pluginArguments.enableCombinedDocumentation
        let features = try? DocCFeatures(doccExecutable: docc)
        if action == .convert && combined && features?.contains(.linkDependencies) == false {
            throw VaporRouteExtractionError("This DocC version does not support --enable-combined-documentation.")
        }

        let snippetTool = try context.tool(named: "snippet-extract")
        let snippetExtractor = SnippetExtractor(
            snippetTool: URL(fileURLWithPath: snippetTool.path.string),
            workingDirectory: URL(fileURLWithPath: context.pluginWorkDirectory.string, isDirectory: true)
        )

        func documentationInputs(for target: SourceModuleTarget) throws -> VaporDocumentationInputs {
            let graphs = try packageManager.doccSymbolGraphs(
                for: target, context: context, verbose: verbose,
                snippetExtractor: snippetExtractor,
                customSymbolGraphOptions: parsed.symbolGraphArguments
            )
            return try graphs.addingVaporDocumentation(
                for: target, context: context, options: options,
                warningsAsErrors: vaporArguments.warningsAsErrors
            )
        }

        if action == .preview {
            let target = targets[0]
            let inputs = try documentationInputs(for: target)
            let arguments = parsed.doccArguments(
                action: .preview,
                targetKind: target.kind == .executable ? .executable : .library,
                doccCatalogPath: inputs.generatedCatalogPath,
                targetName: target.name,
                symbolGraphDirectoryPath: inputs.unifiedSymbolGraphsDirectory.path,
                outputPath: parsed.outputDirectory?.path ?? target.doccArchiveOutputPath(in: context)
            )
            try preview(docc: docc, arguments: arguments, verbose: verbose)
            return
        }

        let intermediates = URL(fileURLWithPath: context.pluginWorkDirectory.string, isDirectory: true)
            .appendingPathComponent("intermediates", isDirectory: true)
        try FileManager.default.createDirectory(at: intermediates, withIntermediateDirectories: true)
        let graph = DocumentationBuildGraphRunner(buildGraph: DocumentationBuildGraph(
            targets: targets.map { SourceModuleDocumentationBuildGraphTarget(sourceTarget: $0) }
        ))
        let archives = try graph.perform { task -> URL? in
            let target = task.target.sourceTarget
            print("Extracting symbol information for '\(target.name)'...")
            let inputs = try documentationInputs(for: target)
            let archive = intermediates.appendingPathComponent("\(target.name).doccarchive", isDirectory: true)
            let dependencies = combined ? task.dependencies.map {
                intermediates.appendingPathComponent("\($0.target.name).doccarchive").path
            } : []
            let arguments = parsed.doccArguments(
                action: .convert,
                targetKind: target.kind == .executable ? .executable : .library,
                doccCatalogPath: inputs.generatedCatalogPath,
                targetName: target.name,
                symbolGraphDirectoryPath: inputs.unifiedSymbolGraphsDirectory.path,
                outputPath: archive.path,
                dependencyArchivePaths: dependencies
            )
            try runDocC(docc, arguments: arguments, verbose: verbose)
            return archive
        }.compactMap { $0 }

        guard !archives.isEmpty else { throw VaporRouteExtractionError("No documentation archives were generated.") }
        if combined {
            let archiveName = context.package.displayName
                .components(separatedBy: CharacterSet.whitespaces.union(.punctuationCharacters))
                .filter { !$0.isEmpty }.joined(separator: "-")
            let destination = parsed.outputDirectory ?? URL(fileURLWithPath: context.pluginWorkDirectory.string)
                .appendingPathComponent("\(archiveName).doccarchive")
            var merge = CommandLineArguments(["merge"] + archives.map(\.path))
            merge.insertIfMissing(DocCArguments.outputPath, value: destination.path)
            if features?.contains(.synthesizedLandingPageName) == true {
                merge.insertIfMissing(DocCArguments.synthesizedLandingPageName, value: context.package.displayName)
                merge.insertIfMissing(DocCArguments.synthesizedLandingPageKind, value: "Package")
            }
            try? FileManager.default.removeItem(at: destination)
            try runDocC(docc, arguments: merge.remainingArguments, verbose: verbose)
            print("Generated combined documentation archive at:\n  \(destination.standardizedFileURL.path)")
        } else {
            let output = parsed.outputDirectory ?? URL(fileURLWithPath: context.pluginWorkDirectory.string)
            if archives.count > 1 { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
            for archive in archives {
                let destination = archives.count == 1 && parsed.outputDirectory != nil
                    ? output : output.appendingPathComponent(archive.lastPathComponent)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: archive, to: destination)
                print("Generated documentation archive at:\n  \(destination.standardizedFileURL.path)")
            }
        }
    }

    private func runDocC(_ executable: URL, arguments: [String], verbose: Bool) throws {
        if verbose { print("docc invocation: '\(executable.path) \(arguments.joined(separator: " "))'") }
        let process = try Process.run(executable, arguments: arguments)
        process.waitUntilExit()
        guard process.terminationReason == .exit && process.terminationStatus == 0 else {
            throw VaporRouteExtractionError("'docc \(arguments.first ?? "")' failed (exit \(process.terminationStatus)).")
        }
    }

    private func preview(docc: URL, arguments: [String], verbose: Bool) throws {
        if verbose { print("docc invocation: '\(docc.path) \(arguments.joined(separator: " "))'") }
        let process = Process()
        process.executableURL = docc
        process.arguments = arguments

        func stop() {
            #if canImport(Darwin)
            process.interrupt()
            #elseif os(Windows)
            _ = TerminateProcess(process.processHandle, 0)
            #else
            kill(process.processIdentifier, SIGKILL)
            #endif
        }

        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM)
        let interruption = DispatchSource.makeSignalSource(signal: SIGINT)
        termination.setEventHandler { stop() }
        interruption.setEventHandler { stop() }
        termination.resume()
        interruption.resume()
        defer { termination.cancel(); interruption.cancel() }

        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit && process.terminationStatus == 0 else {
            throw VaporRouteExtractionError("'docc preview' failed (exit \(process.terminationStatus)). Pass --disable-sandbox for local network access.")
        }
    }
}

private struct SourceModuleDocumentationBuildGraphTarget: DocumentationBuildGraphTarget {
    let sourceTarget: SourceModuleTarget
    var id: String { sourceTarget.id }
    var name: String { sourceTarget.name }
    var dependencyIDs: [String] {
        sourceTarget.dependencies.flatMap {
            switch $0 {
            case .target(let target): return [target.id]
            case .product(let product): return product.targets.map(\.id)
            @unknown default: return []
            }
        }
    }
}
