// swift-tools-version: 5.9
import Foundation
import PackageDescription

let package = Package(
    name: "VaporRoutesFixture",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.115.0"),
    ],
    targets: [
        .executableTarget(name: "Server", dependencies: [.product(name: "Vapor", package: "vapor")]),
    ]
)

if FileManager.default.fileExists(atPath: "../swift-docc-plugin") {
    package.dependencies.append(.package(path: "../swift-docc-plugin"))
}
