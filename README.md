# BenchmarkHarness

Stable, reproducible benchmark numbers for [ordo-one/benchmark](https://github.com/ordo-one/benchmark)
on a machine that is busy with other work. Instead of timing each iteration, the
`benchmark-harness` tool runs the benchmark executables unchanged inside a Linux virtual machine,
under Valgrind's Callgrind on a fixed simulated cache and branch predictor, and counts the work
each iteration does: instructions, cache misses, mispredicted branches and an estimated cycle
count. Host load changes none of these counts, so two runs agree to within a few instructions. The
counts are written as an ordinary ordo-one baseline, which `swift package benchmark baseline
compare` and `check` read as they read any other.

[Documentation](https://tyler-keith-thompson.github.io/BenchmarkHarness/documentation/)

## Installation

BenchmarkHarness requires Swift 6.3 and supports macOS 15, iOS 18, tvOS 18, watchOS 11 and visionOS 2
or later.

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

## Usage

### Recording a simulated baseline

The host tool lives in `Harness/` and requires macOS 26 on Apple silicon, because it boots its
virtual machine through Apple's Containerization framework. Benchmarks are declared as ordo-one
declares them; nothing in a benchmark target changes.

```sh
just harness   # build and sign Harness/.build/release/benchmark-harness
Harness/.build/release/benchmark-harness baseline update main --package-path Benchmarks
cd Benchmarks && swift package benchmark baseline compare main
```

`baseline update` builds every target that uses `BenchmarkPlugin` in release inside the virtual
machine, runs each benchmark through ordo-one's own runner protocol, and writes
`.benchmarkBaselines/<target>/<name>/results.json`. `--target`, `--filter` and `--skip` narrow the
run, as they do for `swift package benchmark`. The first run downloads a Linux kernel, the Swift
image and Valgrind, and builds Valgrind; later runs reuse the cache in
`~/Library/Caches/BenchmarkHarness`.

Simulation is slow: a measured iteration runs roughly fifty times slower than natively. The tool
keeps that cost to what is measured:

- Each benchmark measures exactly three iterations (`--iterations`), or fewer when its own
  `maxIterations` is lower, whatever its time limit and however busy the machine is. Its own
  warmup iterations run first.
- Callgrind instruments each benchmark only from the start of its measurement to its last
  iteration, so registration, setup and warmup run several times faster.
- Each benchmark runs in a process of its own, so its counts don't depend on which benchmarks ran
  before it or were filtered out, and benchmarks are measured side by side (`--jobs`, by default
  the virtual machine's `--cpus`), since one Callgrind process uses one processor.

Several runs, from different packages or checkouts, can run at once.

The virtual machine has no network interface. Package resolution inside it goes through an HTTPS
`CONNECT` proxy that listens on a Unix socket readable only by the current user and admits port
443 alone.

### The library

The modules that read Callgrind's dumps and write ordo-one's baselines are a library. Every example
here is a test in `Tests/BenchmarkHarnessTests`, so it cannot drift from the code.

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

### Metrics

| Metric | Counts |
|---|---|
| Instructions | Instructions executed (Callgrind's `Ir`) |
| L1 Miss Sum | Level-1 instruction and data cache misses, on a 32 KiB 8-way cache with 64-byte lines |
| Last-level Miss Sum | Last-level cache misses, on an 8 MiB 16-way cache |
| Mispredicted Branch | Mispredicted conditional and indirect branches |
| Cycle Estimation | `Ir + 10 × (L1 misses + mispredicted branches) + 100 × last-level misses` |

Each metric is counted inside ordo-one's own measurement window, from the counter reset before an
iteration to the counter read after it, less the median cost of an empty window. An empty
benchmark still measures a few hundred instructions, ordo-one's own per-iteration bookkeeping,
which is the same in every run and so cancels out of a comparison.

The value recorded is the median over the measured iterations. The simulated caches and branch
predictor start cold at the first measured iteration and stay warm after it, so with three
iterations the median is a warm one.

## Development

Bazel is the development build; SwiftPM is the published package. Both are generated from
`scripts/modules.py`.

| Command | Does |
|---|---|
| `just test` | Build and run every test |
| `just verify` | The tests under Bazel and under SwiftPM |
| `just modules` | Regenerate `Package.swift` and every `BUILD.bazel` |
| `just docs` | The DocC site into `.build/docs` |
| `just bench` | The benchmarks (`Benchmarks/README.md`) |
| `just bench-simulated` | The benchmarks' simulated counts, as the `simulated` baseline |
| `just bench-simulated-compare` | Simulated counts now, compared against `simulated` |
| `just harness-test` | The host tool's tests |
| `just generate` | An Xcode project from the Bazel graph |

`AGENTS.md` describes the layout, the workflow and the house rules in full.

## License

MIT. See `LICENSE`.
