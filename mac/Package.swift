// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Bridg",

    platforms: [
        .macOS(.v13)
    ],

    products: [
        .executable(
            name: "Bridg",
            targets: ["Bridg"]
        )
    ],

    dependencies: [
        // Protobuf for Swift
        .package(
            url: "https://github.com/apple/swift-protobuf.git",
            from: "1.26.0"
        ),

        // GRDB for SQLite
        .package(
            url: "https://github.com/groue/GRDB.swift.git",
            from: "6.24.0"
        )
    ],

    targets: [
        .executableTarget(
            name: "Bridg",

            dependencies: [
                .product(
                    name: "SwiftProtobuf",
                    package: "swift-protobuf"
                ),

                .product(
                    name: "GRDB",
                    package: "GRDB.swift"
                )
            ],

            path: "Sources/Bridg"
        ),

        .testTarget(
            name: "BridgTests",
            dependencies: ["Bridg"],
            path: "Tests/BridgTests"
        )
    ]
)
