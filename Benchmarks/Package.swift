// swift-tools-version: 6.3
import PackageDescription

// Benchmarks live in their own package so the library and its tests never depend on the
// benchmark framework. Run them with `just bench`; see Benchmarks/README.md.

let package = Package(
    name: "BenchmarkHarnessBenchmarks",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Named, so the identity does not depend on the checkout directory's name.
        .package(name: "BenchmarkHarness", path: ".."),
        .package(url: "https://github.com/ordo-one/benchmark", from: "1.27.0"),
    ],
    targets: [
        .executableTarget(
            name: "CallgrindBenchmarks",
            dependencies: [
                .product(name: "Benchmark", package: "benchmark"),
                .product(name: "Callgrind", package: "BenchmarkHarness"),
            ],
            path: "Benchmarks/CallgrindBenchmarks",
            plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]
        ),
        .executableTarget(
            name: "LongIterationBenchmarks",
            dependencies: [.product(name: "Benchmark", package: "benchmark")],
            path: "Benchmarks/LongIterationBenchmarks",
            plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]
        ),
        .executableTarget(
            name: "MeasurementWindowBenchmarks",
            dependencies: [.product(name: "Benchmark", package: "benchmark")],
            path: "Benchmarks/MeasurementWindowBenchmarks",
            plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]
        ),
        .executableTarget(
            name: "ThreadBenchmarks",
            dependencies: [.product(name: "Benchmark", package: "benchmark")],
            path: "Benchmarks/ThreadBenchmarks",
            plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]
        ),
        .executableTarget(
            name: "SimulatedMetricsBenchmarks",
            dependencies: [
                .product(name: "Benchmark", package: "benchmark"),
                .product(name: "Callgrind", package: "BenchmarkHarness"),
                .product(name: "BenchmarkBaselines", package: "BenchmarkHarness"),
                .product(name: "SimulatedMetrics", package: "BenchmarkHarness"),
            ],
            path: "Benchmarks/SimulatedMetricsBenchmarks",
            plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]
        ),
    ]
)
