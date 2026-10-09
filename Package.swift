// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Simless",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "simless", targets: ["simless"]),
    ],
    targets: [
        .executableTarget(
            name: "simless",
            path: "Sources/simless",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
