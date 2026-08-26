// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CiscoConnect",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CiscoConnect", targets: ["CiscoConnect"]),
    ],
    targets: [
        .executableTarget(
            name: "CiscoConnect",
            path: "Sources/CiscoConnect"
        ),
        .testTarget(
            name: "CiscoConnectTests",
            dependencies: ["CiscoConnect"],
            path: "Tests/CiscoConnectTests"
        ),
    ]
)

