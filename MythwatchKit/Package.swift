// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MythwatchKit",
    platforms: [.macOS(.v15), .tvOS("26.0")],
    products: [
        .library(name: "MythwatchDomain", targets: ["MythwatchDomain"]),
        .library(name: "MythwatchBackend", targets: ["MythwatchBackend"]),
        .library(name: "MythBackendV35", targets: ["MythBackendV35"]),
        .library(name: "MythwatchPlayback", targets: ["MythwatchPlayback"]),
        .library(name: "MythwatchFeatures", targets: ["MythwatchFeatures"]),
        .library(name: "MythwatchTestSupport", targets: ["MythwatchTestSupport"]),
    ],
    targets: [
        .target(name: "MythwatchDomain"),
        .target(name: "MythwatchBackend", dependencies: ["MythwatchDomain"]),
        .target(name: "MythBackendV35", dependencies: ["MythwatchBackend", "MythwatchDomain"]),
        .target(name: "MythwatchPlayback", dependencies: ["MythwatchDomain"]),
        .target(
            name: "MythwatchFeatures",
            dependencies: ["MythwatchDomain", "MythwatchBackend", "MythwatchPlayback"]),
        .target(
            name: "MythwatchTestSupport",
            dependencies: [
                "MythwatchDomain", "MythwatchBackend", "MythwatchPlayback", "MythwatchFeatures",
            ]),
        .testTarget(name: "MythwatchDomainTests", dependencies: ["MythwatchDomain"]),
        .testTarget(name: "MythwatchBackendTests", dependencies: ["MythwatchBackend"]),
        .testTarget(name: "MythBackendV35Tests", dependencies: ["MythBackendV35"]),
        .testTarget(name: "MythwatchPlaybackTests", dependencies: ["MythwatchPlayback"]),
        .testTarget(name: "MythwatchFeaturesTests", dependencies: ["MythwatchFeatures"]),
    ],
    swiftLanguageModes: [.v6]
)
