// swift-tools-version: 6.2
import PackageDescription

// Runs the cleanup model with MLX. Kept apart from IruddVoiceKit so the
// logic tests don't need MLX. Build with xcodebuild, not `swift build`:
// SwiftPM doesn't compile MLX's Metal shaders.
let package = Package(
    name: "CleanupModel",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "CleanupModel", targets: ["CleanupModel"]),
        .executable(name: "voice-model-tool", targets: ["voice-model-tool"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.5"),
        .package(path: "../IruddVoiceKit"),
    ],
    targets: [
        .target(
            name: "CleanupModel",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                // Gemma 4's assistant drafter and the Gemma 4 class it drafts for.
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "Hub", package: "swift-transformers"),
                .product(name: "IruddVoiceKit", package: "IruddVoiceKit"),
            ]
        ),
        // Headless tool: parity token dumps, evals and benchmarks from the
        // terminal. No windows, no mic, no XPC.
        .executableTarget(name: "voice-model-tool", dependencies: ["CleanupModel"]),
    ]
)
