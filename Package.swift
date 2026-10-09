// swift-tools-version: 6.0
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.
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
