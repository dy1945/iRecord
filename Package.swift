// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "iRecord",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "iRecord",
            path: "Sources/iRecord",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        )
    ]
)
