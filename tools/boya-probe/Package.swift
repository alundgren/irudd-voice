// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "boya-probe",
    platforms: [.macOS("27.0")],
    targets: [
        .executableTarget(
            name: "boya-probe",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
