// swift-tools-version: 6.2
import PackageDescription

// App logic with no UI, so it can be tested headless with `swift test`.
let package = Package(
    name: "IruddVoiceKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "IruddVoiceKit", targets: ["IruddVoiceKit"])
    ],
    targets: [
        .target(name: "IruddVoiceKit"),
        .testTarget(name: "IruddVoiceKitTests", dependencies: ["IruddVoiceKit"]),
    ]
)
