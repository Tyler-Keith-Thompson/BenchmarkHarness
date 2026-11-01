import BenchmarkBaselines
import BenchmarkCommands
import Foundation
import SimulatedMetrics

/// One run of a benchmark executable under Callgrind on a Linux machine, driven by
/// ordo-one/benchmark's runner protocol.
struct BenchmarkProcess<Runner: Machine>: Sendable {
    /// The benchmark target the executable was built from.
    let target: String
    /// The executable's path on the machine.
    let executable: String
    /// The machine the executable runs on.
    let machine: Runner
    /// The machine's path of `run-benchmarks.sh`.
    let script: String
    /// The machine's path of the prefix Valgrind and the shim are installed under.
    let prefix: String
    /// The iterations each benchmark measures.
    let iterations: Int
    /// The host directory the process's dumps and Valgrind log are written to.
    let dumps: URL
    /// The same directory, as the machine sees it.
    let machineDumps: String
    /// Whether the executable runs without Valgrind, for ``count(_:metrics:)``.
    var native = false

    /// The executable's benchmarks.
    func list() async throws -> [Benchmark] {
        try await session(benchmark: nil) { channel in
            channel.send(.list)
            var benchmarks: [Benchmark] = []
            while true {
                switch try await channel.receive() {
                case let .list(benchmark): benchmarks.append(benchmark)
                case .end: return benchmarks
                case let .error(description): throw BenchmarkFailed(target: target, benchmark: nil, description: description)
                default: continue
                }
            }
        }
    }

    /// The result of every ``SimulatedMetric`` for `benchmark`, measured in this process alone.
    func measure(_ benchmark: Benchmark) async throws -> [BenchmarkResult] {
        FileHandle.standardError.write(Data("Measuring \(target): \(benchmark.name)\n".utf8))
        let started = ContinuousClock.now
        return try await session(benchmark: benchmark.name) { channel in
            channel.send(.run(benchmark: benchmark.measuring([.instructions])))
            running: while true {
                switch try await channel.receive() {
                case .end: break running
                case let .error(description): throw BenchmarkFailed(target: target, benchmark: benchmark.name, description: description)
                default: continue
                }
            }
            let (iterations, overhead) = try SimulatedBaselineRecorder.readDumps(in: dumps)
            let results = SimulatedMetric.allCases.map { metric in
                BenchmarkResult(metric: metric, iterations: iterations, overhead: overhead, warmupIterations: benchmark.warmupIterations)
            }
            SimulatedBaselineRecorder.report(
                BenchmarkIdentifier(target: target, name: benchmark.name),
                iterations: iterations,
                overhead: overhead,
                elapsed: started.duration(to: .now),
                results: results
            )
            return results
        }
    }

    /// The results ordo-one/benchmark's own collectors report for `metrics` of `benchmark`, measured
    /// in this process alone; for a process with ``native`` set.
    ///
    /// The instruction counter is requested too, though its counts are dropped: its reads are the
    /// measurement windows the shim counts iterations by.
    func count(_ benchmark: Benchmark, metrics: [BenchmarkMetric]) async throws -> [BenchmarkResult] {
        try await session(benchmark: benchmark.name) { channel in
            channel.send(.run(benchmark: benchmark.measuring(metrics + [.instructions])))
            var results: [BenchmarkResult] = []
            while true {
                switch try await channel.receive() {
                case let .result(_, reported): results += reported.filter { metrics.contains($0.metric) }
                case .end: return results
                case let .error(description): throw BenchmarkFailed(target: target, benchmark: benchmark.name, description: description)
                default: continue
                }
            }
        }
    }

    /// Starts the executable, runs `body` against its protocol channel, then ends it.
    ///
    /// - Parameter benchmark: The benchmark the session runs, if any, for error messages.
    /// - Throws: ``BenchmarkFailed`` when the executable exits with a non-zero code or before
    ///   replying, and whatever else `body` throws.
    private func session<Result: Sendable>(
        benchmark: String?,
        _ body: (inout BenchmarkChannel) async throws -> Result
    ) async throws -> Result {
        let (requests, requestContinuation) = AsyncStream.makeStream(of: Data.self)
        let (replies, replyContinuation) = AsyncStream.makeStream(of: Data.self)
        async let exitCode = machine.run(
            ["/bin/bash", script, prefix, executable, machineDumps, String(iterations), native ? "native" : "callgrind"],
            environment: [],
            input: requests,
            output: replyContinuation
        )
        var channel = BenchmarkChannel(input: requestContinuation, output: replies)
        let result: Result
        do {
            result = try await body(&channel)
            channel.send(.end)
            channel.finish()
        } catch is BenchmarkExecutableExited {
            channel.finish()
            let code = (try? await exitCode).map(String.init) ?? "unknown"
            throw BenchmarkFailed(
                target: target,
                benchmark: benchmark,
                description: "\(target)\(benchmark.map { ": \($0)" } ?? ""): the executable exited with code \(code) before replying; see \(dumps.appending(path: "valgrind.log").path)"
            )
        } catch {
            channel.finish()
            _ = try? await exitCode
            throw error
        }
        let code = try await exitCode
        guard code == 0 else {
            throw BenchmarkFailed(target: target, benchmark: nil, description: "The executable exited with code \(code); see \(dumps.appending(path: "valgrind.log").path)")
        }
        return result
    }
}
