import BenchmarkBaselines
import BenchmarkCommands
import Foundation
import SimulatedMetrics

/// One run of a benchmark executable under Callgrind in the guest, driven by ordo-one/benchmark's
/// runner protocol.
struct BenchmarkProcess: Sendable {
    /// The benchmark target the executable was built from.
    let target: String
    /// The executable's path in the guest.
    let executable: String
    /// The guest the executable runs in.
    let guest: GuestMachine
    /// The guest path of `run-benchmarks.sh`.
    let script: String
    /// The iterations each benchmark measures.
    let iterations: Int
    /// The host directory the process's dumps and Valgrind log are written to.
    let dumps: URL
    /// The same directory, as the guest sees it.
    let guestDumps: String

    /// The executable's benchmarks.
    func list() async throws -> [Benchmark] {
        try await session { channel in
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
        return try await session { channel in
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

    /// Starts the executable, runs `body` against its protocol channel, then ends it.
    ///
    /// - Throws: ``BenchmarkFailed`` when the executable exits with a non-zero code, and whatever
    ///   `body` throws.
    private func session<Result: Sendable>(
        _ body: (inout BenchmarkChannel) async throws -> Result
    ) async throws -> Result {
        let (requests, requestContinuation) = AsyncStream.makeStream(of: Data.self)
        let (replies, replyContinuation) = AsyncStream.makeStream(of: Data.self)
        async let exitCode = guest.run(
            ["/bin/bash", script, executable, guestDumps, String(iterations)],
            standardInput: StreamReader(source: requests),
            standardOutput: StreamWriter(continuation: replyContinuation)
        )
        var channel = BenchmarkChannel(input: requestContinuation, output: replies)
        let result: Result
        do {
            result = try await body(&channel)
            channel.send(.end)
            channel.finish()
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
