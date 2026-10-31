// swift-tools-version: 6.3
import PackageDescription

// The host tool, in a package of its own: it boots a Linux virtual machine through Apple's
// Containerization framework, which needs macOS 26, so the library and its tests stay free of it.
// Bazel ignores this directory (.bazelignore). Build it with `just harness`, which also signs the
// executable with the virtualization entitlement.

let package = Package(
    name: "BenchmarkHarnessHost",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "benchmark-harness", targets: ["benchmark-harness"]),
    ],
    dependencies: [
        // Named, so the identity does not depend on the checkout directory's name.
        .package(name: "BenchmarkHarness", path: ".."),
        .package(url: "https://github.com/apple/containerization", exact: "0.54.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-nio", from: "2.80.0"),
    ],
    targets: [
        .target(
            name: "HarnessHost",
            dependencies: [
                .product(name: "BenchmarkBaselines", package: "BenchmarkHarness"),
                .product(name: "BenchmarkCommands", package: "BenchmarkHarness"),
                .product(name: "Callgrind", package: "BenchmarkHarness"),
                .product(name: "SimulatedMetrics", package: "BenchmarkHarness"),
                .product(name: "Containerization", package: "containerization"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            resources: [.copy("Guest")]
        ),
        .executableTarget(
            name: "benchmark-harness",
            dependencies: [
                "HarnessHost",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "HarnessHostTests",
            dependencies: [
                "HarnessHost",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
    ]
)
