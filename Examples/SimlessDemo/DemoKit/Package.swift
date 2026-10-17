// swift-tools-version: 6.0
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import PackageDescription

// A small local package with two products, like most apps that keep their
// code in packages: simless runs its test target next to the app's.
let package = Package(
    name: "DemoKit",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "DemoKit", targets: ["DemoKit"]),
        .library(name: "DemoFormat", targets: ["DemoFormat"]),
    ],
    targets: [
        .target(name: "DemoKit"),
        .target(name: "DemoFormat"),
        .testTarget(name: "DemoKitTests", dependencies: ["DemoKit", "DemoFormat"]),
    ]
)
