// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TalkType",
    platforms: [.macOS(.v13)],
    targets: [
        // The official prebuilt whisper.cpp, with Metal for the M1's graphics chip.
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-b5454-xcframework.zip",
            checksum: "e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b"
        ),
        .target(name: "TalkTypeCore"),
        .executableTarget(
            name: "TalkType",
            dependencies: ["TalkTypeCore", "whisper"],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .testTarget(name: "TalkTypeCoreTests", dependencies: ["TalkTypeCore"]),
    ]
)
