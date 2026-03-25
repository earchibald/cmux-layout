// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "cmux-layout",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "cmux-layout", targets: ["cmux-layout"]),
        .library(name: "CMUXLayout", targets: ["CMUXLayout"]),
    ],
    targets: [
        .target(name: "CMUXLayout"),
        .executableTarget(
            name: "cmux-layout",
            dependencies: ["CMUXLayout"]
        ),
        .testTarget(
            name: "CMUXLayoutTests",
            dependencies: ["CMUXLayout"]
        ),
    ]
)
