import Foundation

/// A request ordo-one/benchmark's tool sends a benchmark executable.
///
/// A benchmark executable started with `--input-fd` and `--output-fd` reads requests from the
/// first descriptor and writes ``BenchmarkCommandReply`` values to the second. Each message is a
/// frame: its length as an 8-byte little-endian integer, then that many bytes of JSON.
@frozen
public enum BenchmarkCommandRequest: Hashable, Sendable {
    /// Describe every benchmark; the executable replies with one
    /// ``BenchmarkCommandReply/list(benchmark:)`` each, then ``BenchmarkCommandReply/end``.
    case list
    /// Run `benchmark`; the executable replies with its results, or an error, then
    /// ``BenchmarkCommandReply/end``.
    case run(benchmark: Benchmark)
    /// Exit.
    case end

    /// The request's JSON, as ordo-one/benchmark encodes `BenchmarkCommandRequest`.
    public var json: Data {
        switch self {
        case .list: Data(#"{"list":{}}"#.utf8)
        case let .run(benchmark): Data(#"{"run":{"benchmark":"#.utf8) + benchmark.json + Data("}}".utf8)
        case .end: Data(#"{"end":{}}"#.utf8)
        }
    }

    /// The request framed for the executable's input: the JSON's length as an 8-byte
    /// little-endian integer, then the JSON.
    public var frame: Data {
        let json = json
        return withUnsafeBytes(of: Int64(json.count).littleEndian) { Data($0) } + json
    }
}
