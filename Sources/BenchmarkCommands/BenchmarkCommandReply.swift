import BenchmarkBaselines
import Foundation

/// A reply a benchmark executable sends ordo-one/benchmark's tool.
///
/// A ``result(benchmark:results:)`` reply decodes the results of ordo-one/benchmark's own
/// collectors; an ``allocationStacks(benchmark:)`` reply keeps only its benchmark.
@frozen
public enum BenchmarkCommandReply: Equatable, Sendable {
    /// One benchmark, in reply to ``BenchmarkCommandRequest/list``.
    case list(benchmark: Benchmark)
    /// The executable is ready.
    case ready
    /// The results of running `benchmark`, one per metric it measured.
    case result(benchmark: Benchmark, results: [BenchmarkResult])
    /// The allocation stacks recorded while running `benchmark`.
    case allocationStacks(benchmark: Benchmark)
    /// The executable started running a benchmark.
    case run
    /// The end of the replies to one request.
    case end
    /// The request failed.
    case error(String)

    /// The reply that `json` encodes, as ordo-one/benchmark encodes `BenchmarkCommandReply`.
    ///
    /// - Parameter json: A JSON object with a single key naming the case.
    /// - Throws: ``MalformedBenchmarkCommand`` when `json` is not a reply.
    public init(json: Data) throws(MalformedBenchmarkCommand) {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              object.count == 1, let (key, value) = object.first,
              let payload = value as? [String: Any]
        else {
            throw MalformedBenchmarkCommand()
        }
        func benchmark() throws(MalformedBenchmarkCommand) -> Benchmark {
            guard let benchmark = payload["benchmark"],
                  let data = try? JSONSerialization.data(withJSONObject: benchmark, options: [.sortedKeys])
            else {
                throw MalformedBenchmarkCommand()
            }
            return try Benchmark(json: data)
        }
        switch key {
        case "list": self = try .list(benchmark: benchmark())
        case "ready": self = .ready
        case "result":
            guard let results = payload["results"],
                  let data = try? JSONSerialization.data(withJSONObject: results),
                  let decoded = try? JSONDecoder().decode([BenchmarkResult].self, from: data)
            else {
                throw MalformedBenchmarkCommand()
            }
            self = try .result(benchmark: benchmark(), results: decoded)
        case "allocationStacks": self = try .allocationStacks(benchmark: benchmark())
        case "run": self = .run
        case "end": self = .end
        case "error":
            guard let description = payload["_0"] as? String else { throw MalformedBenchmarkCommand() }
            self = .error(description)
        default: throw MalformedBenchmarkCommand()
        }
    }
}

/// The error thrown for bytes that are not a frame, reply or benchmark of ordo-one/benchmark's
/// protocol.
@frozen
public struct MalformedBenchmarkCommand: Error, Hashable, Sendable {
    @inlinable
    public init() {}
}
