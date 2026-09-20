// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "iRecord",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .target(name: "ControlProtocol"),
        .testTarget(name: "ControlProtocolTests", dependencies: ["ControlProtocol"]),
        .executableTarget(name: "IRecordCLI", dependencies: ["ControlProtocol"]),
        .executableTarget(
            name: "iRecord",
            dependencies: ["ControlProtocol"],
            path: "Sources/iRecord",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        )
    ]
)
