import Benchmark
import BenchmarkBaselines
import Callgrind
import SimulatedMetrics

let benchmarks: @Sendable () -> Void = {
    Benchmark.defaultConfiguration.metrics = [.wallClock, .instructions, .mallocCountTotal]
    Benchmark.defaultConfiguration.maxDuration = .seconds(2)
    Benchmark.defaultConfiguration.maxIterations = 50

    // try! can't fire: every dump below is a literal that names its events and whose totals are
    // non-negative integers, and the benchmarks registry closure cannot throw.
    let iterations = (0 ..< 100).map { index in
        try! CallgrindDump(text: "events: Ir I1mr D1mr D1mw ILmr DLmr DLmw Bcm Bim\ntotals: \(4000 + index) 2 9 3 0 1 0 12 1\n")
    }
    let overhead = (0 ..< 5).map { _ in
        try! CallgrindDump(text: "events: Ir I1mr D1mr D1mw ILmr DLmr DLmw Bcm Bim\ntotals: 100\n")
    }

    // The hand-written form the library must keep pace with: subtract and sort the raw values.
    Benchmark("SimulatedMetrics: BASELINE per-iteration instructions less overhead") { benchmark in
        for _ in benchmark.scaledIterations {
            let values = iterations.map { ($0.totals[.instructionCacheReads] ?? 0) - 100 }.sorted()
            blackHole(values)
        }
    }

    Benchmark("SimulatedMetrics: BenchmarkResult(metric:iterations:overhead:warmupIterations:), every metric") { benchmark in
        for _ in benchmark.scaledIterations {
            for metric in SimulatedMetric.allCases {
                blackHole(try BenchmarkResult(metric: metric, iterations: iterations, overhead: overhead, warmupIterations: 1))
            }
        }
    }
}
