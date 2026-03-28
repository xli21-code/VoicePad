// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoicePad",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "CSherpaOnnx",
            path: "Sources/CSherpaOnnx",
            publicHeadersPath: "include",
            linkerSettings: [
                .unsafeFlags([
                    "-L", "Frameworks/sherpa-onnx/lib",
                    "-lsherpa-onnx-c-api",
                    "-lonnxruntime",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                ]),
            ]
        ),
        .executableTarget(
            name: "VoicePad",
            dependencies: [
                "CSherpaOnnx",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/VoicePad"
        ),
        .testTarget(
            name: "VoicePadTests",
            dependencies: ["VoicePad"],
            path: "Tests/VoicePadTests"
        ),
    ]
)
