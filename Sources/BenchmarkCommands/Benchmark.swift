import BenchmarkBaselines
import Foundation

/// A benchmark as a benchmark executable describes it in a ``BenchmarkCommandReply/list(benchmark:)``
/// reply.
///
/// The executable's JSON is kept as received, so a ``BenchmarkCommandRequest/run(benchmark:)``
/// request sends back every setting it does not change, whatever version of
/// ordo-one/benchmark wrote it.
@frozen
public struct Benchmark: Hashable, Sendable {
    /// The benchmark's name, unique within its executable.
    public let name: String
    /// The iterations the benchmark runs before measuring.
    public let warmupIterations: Int
    /// The benchmark's JSON, as ordo-one/benchmark encodes its `Benchmark` class.
    public let json: Data

    /// The benchmark that `json` encodes.
    ///
    /// - Parameter json: An ordo-one/benchmark `Benchmark` encoded as JSON.
    /// - Throws: ``MalformedBenchmarkCommand`` when `json` is not an object with a string `name`
    ///   and a `configuration` object.
    public init(json: Data) throws(MalformedBenchmarkCommand) {
        guard let header = try? JSONDecoder().decode(Header.self, from: json) else {
            throw MalformedBenchmarkCommand()
        }
        self.name = header.name
        self.warmupIterations = header.configuration.warmupIterations ?? 0
        self.json = json
    }

    /// The same benchmark, measuring only `metrics`.
    ///
    /// A benchmark executable measures the metrics of the benchmark it is asked to run, so the
    /// result is what to send in a ``BenchmarkCommandRequest/run(benchmark:)`` request.
    ///
    /// - Parameter metrics: The metrics to measure.
    /// - Complexity: O(*n*), where *n* is the length of ``json``.
    public func measuring(_ metrics: [BenchmarkMetric]) -> Benchmark {
        guard var object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              var configuration = object["configuration"] as? [String: Any],
              let encodedMetrics = try? JSONEncoder().encode(metrics),
              let metricObjects = try? JSONSerialization.jsonObject(with: encodedMetrics),
              let replaced = try? { () throws -> Data in
                  configuration["metrics"] = metricObjects
                  object["configuration"] = configuration
                  return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
              }(),
              let benchmark = try? Benchmark(json: replaced)
        else {
            preconditionFailure("A benchmark's JSON was validated when it was decoded")
        }
        return benchmark
    }

    private struct Header: Decodable {
        struct Configuration: Decodable {
            let warmupIterations: Int?
        }

        let name: String
        let configuration: Configuration
    }
}
