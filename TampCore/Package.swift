// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "TampCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TampCore", targets: ["TampCore"]),
        .executable(name: "tamp-bench", targets: ["TampBench"]),
    ],
    targets: [
        .target(name: "TampCore"),
        .executableTarget(name: "TampBench", dependencies: ["TampCore"]),
        .testTarget(name: "TampCoreTests", dependencies: ["TampCore"], resources: [.copy("Corpus")]),
    ]
)
