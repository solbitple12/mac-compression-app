// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "TampCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TampCore", targets: ["TampCore"]),
    ],
    targets: [
        .target(name: "TampCore"),
        .testTarget(name: "TampCoreTests", dependencies: ["TampCore"]),
    ]
)
