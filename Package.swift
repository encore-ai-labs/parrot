// swift-tools-version:5.9
import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let embeddedInfoPlist = "\(packageRoot)/Support/Parrot-Info.plist"

let package = Package(
    name: "parrot",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        // v1.1.0 fixes an upstream decoder bug where any promptTokens (used by
        // personal vocabulary and note commands) could return an empty transcript.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.0"),
        // Parakeet Unified is the fast, punctuation-aware local English path.
        // Pin the minor line: FluidAudio moves quickly and its model APIs are
        // not yet 1.0-stable.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", .upToNextMinor(from: "0.15.6")),
    ],
    targets: [
        .executableTarget(
            name: "parrot",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", embeddedInfoPlist,
                ]),
            ]
        ),
        .testTarget(
            name: "parrotTests",
            dependencies: ["parrot"]
        ),
    ]
)
