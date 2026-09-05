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
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "parrot",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "WhisperKit", package: "WhisperKit"),
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
