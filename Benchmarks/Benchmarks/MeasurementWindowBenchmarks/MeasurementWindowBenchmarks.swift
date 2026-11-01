import Benchmark

// Fixtures for benchmark-harness's measurement windows rather than benchmarks of the library: each
// measures the same thousand calls, so their simulated instruction counts must match whether the
// closure is measured whole or between its own startMeasurement() and stopMeasurement(), with a
// million calls of setup and teardown outside them.

@inline(never)
func call(_ count: Int) {
    for value in 0 ..< count {
        blackHole(value)
    }
}

let benchmarks: @Sendable () -> Void = {
    Benchmark.defaultConfiguration.metrics = [.wallClock, .instructions]
    Benchmark.defaultConfiguration.maxDuration = .seconds(2)
    Benchmark.defaultConfiguration.maxIterations = 50

    Benchmark("Measurement window: a thousand calls") { _ in
        call(1000)
    }

    Benchmark("Measurement window: a thousand calls between startMeasurement() and stopMeasurement()") { benchmark in
        call(1_000_000)
        benchmark.startMeasurement()
        call(1000)
        benchmark.stopMeasurement()
        call(1_000_000)
    }

    Benchmark("Measurement window: a thousand calls after startMeasurement()") { benchmark in
        call(1_000_000)
        benchmark.startMeasurement()
        call(1000)
    }
}
