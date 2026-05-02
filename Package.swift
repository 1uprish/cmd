// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClipLog",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ClipLog", targets: ["ClipLog"]),
        .library(name: "ClipLogCore", targets: ["ClipLogCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "ClipLogCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/ClipLogCore",
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=complete"]),
            ]
        ),
        .executableTarget(
            name: "ClipLog",
            dependencies: [
                "ClipLogCore",
            ],
            path: "Sources/ClipLog",
            exclude: [
                "Info.plist",
                "Resources/cmd.entitlements",
            ],
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "ClipLogTests",
            dependencies: ["ClipLogCore"],
            path: "Tests/ClipLogTests"
        ),
    ]
)
