// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Shelf",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Shelf",
            path: "Sources/Shelf",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        )
    ]
)
