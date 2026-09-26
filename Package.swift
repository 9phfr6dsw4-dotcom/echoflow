// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "EchoFlow",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "EchoFlowCore", targets: ["EchoFlowCore"]),
        .executable(name: "EchoFlowApp", targets: ["EchoFlowApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.2"),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.0")
    ],
    targets: [
        .target(name: "EchoFlowCore", resources: [.copy("Resources/model-manifest.json")]),
        .executableTarget(
            name: "EchoFlowApp",
            dependencies: [
                "EchoFlowCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "argmax-oss-swift")
            ]
        ),
        .testTarget(
            name: "EchoFlowTests",
            dependencies: ["EchoFlowCore", .product(name: "WhisperKit", package: "argmax-oss-swift")]
        )
    ]
)
