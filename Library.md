# The BenchmarkHarness library

The modules that read Callgrind's dumps and write ordo-one's baselines are also a SwiftPM library,
for tools that want to record simulated baselines themselves. Most people only need the
`benchmark-harness` tool ([README](../README.md)).

The library requires Swift 6.3 and supports macOS 15, iOS 18, tvOS 18, watchOS 11 and visionOS 2
or later, and Linux.

```swift
dependencies: [
    .package(url: "https://github.com/Tyler-Keith-Thompson/BenchmarkHarness", from: "0.0.1"),
],
```

Then add a product to your target, either the umbrella or individual modules:

```swift
.target(name: "MyApp", dependencies: [
    .product(name: "BenchmarkHarness", package: "BenchmarkHarness"),
    // or, for example:
    // .product(name: "SimulatedMetrics", package: "BenchmarkHarness"),
]),
```

This example is a test in `Tests/BenchmarkHarnessTests`, so it cannot drift from the code:

```swift
import BenchmarkHarness

let iterations = [
    CallgrindDump(text: "events: Ir I1mr D1mr D1mw ILmr DLmr DLmw Bcm Bim\ntotals: 4100 2 9 3 0 1 0 12\n"),
    CallgrindDump(text: "events: Ir I1mr D1mr D1mw ILmr DLmr DLmw Bcm Bim\ntotals: 4100 0 8 3 0 0 0 12\n"),
]
let overhead = [
    CallgrindDump(text: "events: Ir I1mr D1mr D1mw ILmr DLmr DLmw Bcm Bim\ntotals: 100\n"),
]
let results = SimulatedMetric.allCases.map { metric in
    BenchmarkResult(metric: metric, iterations: iterations, overhead: overhead, warmupIterations: 1)
}
let baseline = BenchmarkBaseline(
    baselineName: "main",
    machine: BenchmarkMachine(hostname: "guest", processors: 8, processorType: "aarch64",
                              memory: 8, kernelVersion: "6.12.28"),
    results: [BenchmarkIdentifier(target: "SortBenchmarks", name: "Sort 1000"): results]
)
let json = try JSONEncoder().encode(baseline)
print(BenchmarkBaseline.relativePath(target: "SortBenchmarks", baselineName: "main"))
// .benchmarkBaselines/SortBenchmarks/main/results.json
```

The API reference is on the [documentation site](https://tyler-keith-thompson.github.io/BenchmarkHarness/documentation/).
