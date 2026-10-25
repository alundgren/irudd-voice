// swift-tools-version: 6.2
import PackageDescription

// App logic with no UI, so it can be tested headless with `swift test`.
let package = Package(
    name: "IruddVoiceKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "IruddVoiceKit", targets: ["IruddVoiceKit"]),
    ],
    targets: [
        .target(name: "IruddVoiceKit"),
        // Test helper: drives the app's real database code from shell tests
        // (with the Python CLI on the other side). Not part of the app.
        .executableTarget(name: "voice-db-tool", dependencies: ["IruddVoiceKit"]),
        .testTarget(name: "IruddVoiceKitTests", dependencies: ["IruddVoiceKit"]),
    ]
)
