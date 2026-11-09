import Benchmark

// Fixtures for benchmark-harness's measurement windows on several threads rather than benchmarks
// of the library. Each measures calls made on a thread other than the one that opens the window,
// so their simulated instruction counts must grow with the number of calls and repeat exactly
// between recordings.

@inline(never)
func call(_ count: Int) {
    for value in 0 ..< count {
        blackHole(value)
    }
}

/// An actor of its own, so a call to it leaves the caller's executor.
actor Worker {
    func call(_ count: Int) {
        ThreadBenchmarks.call(count)
    }
}

let benchmarks: @Sendable () -> Void = {
    Benchmark.defaultConfiguration.metrics = [.wallClock, .instructions]
    Benchmark.defaultConfiguration.maxDuration = .seconds(2)
    Benchmark.defaultConfiguration.maxIterations = 50

    Benchmark("Threads: a thousand calls on a detached task") { _ in
        await Task.detached { call(1000) }.value
    }

    Benchmark("Threads: ten thousand calls on a detached task") { _ in
        await Task.detached { call(10_000) }.value
    }

    Benchmark("Threads: a thousand calls on the main actor") { _ in
        await MainActor.run { call(1000) }
    }

    Benchmark("Threads: a thousand calls on an actor, between hops") { _ in
        let worker = Worker()
        await Task.yield()
        await worker.call(1000)
        await Task.yield()
    }
}
