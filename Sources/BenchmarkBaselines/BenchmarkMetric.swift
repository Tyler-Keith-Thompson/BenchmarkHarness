/// A metric of an ordo-one/benchmark result: the built-in instruction count, or a custom metric.
///
/// The cases encode exactly as ordo-one/benchmark's `BenchmarkMetric` does, so a baseline holding
/// them is one ordo-one's tool reads, compares and checks thresholds against.
@frozen
public enum BenchmarkMetric: Hashable, Sendable, Codable {
    /// The number of instructions executed.
    case instructions
    /// A metric ordo-one/benchmark does not define, identified by its name.
    ///
    /// - Parameters:
    ///   - name: The name the tool prints and matches thresholds against.
    ///   - polarity: Whether smaller or larger values are better.
    ///   - useScalingFactor: Whether values are divided by the benchmark's scaling factor.
    case custom(_ name: String, polarity: Polarity = .prefersSmaller, useScalingFactor: Bool = true)

    /// Whether smaller or larger values of a metric are better.
    @frozen
    public enum Polarity: Hashable, Sendable, Codable {
        /// Larger values are better, as for throughput.
        case prefersLarger
        /// Smaller values are better, as for time and counts of work.
        case prefersSmaller
    }

    /// Whether larger values of the metric are better.
    @inlinable
    public var prefersLarger: Bool {
        switch self {
        case .instructions: false
        case let .custom(_, polarity, _): polarity == .prefersLarger
        }
    }
}
