/// The measurements of one metric of one benchmark, as ordo-one/benchmark stores them in a baseline.
///
/// Results encode as ordo-one/benchmark's `BenchmarkResult`, and results it encoded, such as those
/// in a ``BenchmarkCommandReply/result(benchmark:results:)`` reply, decode to their metric,
/// scaling factor, warmup and statistics; tags and thresholds are not kept.
@frozen
public struct BenchmarkResult: Equatable, Sendable, Codable {
    /// The metric measured.
    public let metric: BenchmarkMetric
    /// The measurements, one per iteration.
    public let statistics: Statistics
    /// The iterations run before measuring began.
    public let warmupIterations: Int
    /// The inner iterations each measurement covers, which ordo-one/benchmark's tool divides
    /// metrics that use it by: 1, or a power of 1000 up to 10¹².
    public let scalingFactor: Int

    /// The result of measuring `metric` once per iteration.
    ///
    /// - Parameters:
    ///   - metric: The metric measured.
    ///   - measurements: One value per measured iteration.
    ///   - warmupIterations: The iterations run before measuring began. Traps when negative.
    /// Each measurement covers one iteration: the ``scalingFactor`` is 1.
    ///
    /// - Complexity: O(*n*), where *n* is the number of measurements.
    public init(metric: BenchmarkMetric, measurements: some Sequence<UInt64>, warmupIterations: Int) {
        precondition(warmupIterations >= 0, "Warmup iterations cannot be negative")
        self.metric = metric
        self.statistics = Statistics(measurements: measurements, prefersLarger: metric.prefersLarger)
        self.warmupIterations = warmupIterations
        self.scalingFactor = 1
    }

    /// The time units ordo-one/benchmark displays the result in, derived from the measurements:
    /// `nanoseconds` for ``Statistics/Units/count`` up to `megaseconds` for ``Statistics/Units/peta``.
    public var timeUnits: String {
        switch statistics.units {
        case .count: "nanoseconds"
        case .kilo: "microseconds"
        case .mega: "milliseconds"
        case .giga: "seconds"
        case .tera: "kiloseconds"
        case .peta: "megaseconds"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case metric
        case timeUnits
        case scalingFactor
        case warmupIterations
        case tags
        case statistics
    }

    /// The scaling factors ordo-one/benchmark defines, from `one` to `tera`.
    private static let scalingFactors: Set<Int> = [1, 1_000, 1_000_000, 1_000_000_000, 1_000_000_000_000]

    /// Decodes a result as ordo-one/benchmark encodes it.
    ///
    /// - Throws: `DecodingError` when a key is missing, a warmup count is negative, or the
    ///   scaling factor is not one ordo-one/benchmark defines.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.metric = try container.decode(BenchmarkMetric.self, forKey: .metric)
        self.statistics = try container.decode(Statistics.self, forKey: .statistics)
        self.warmupIterations = try container.decode(Int.self, forKey: .warmupIterations)
        self.scalingFactor = try container.decode(Int.self, forKey: .scalingFactor)
        guard warmupIterations >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .warmupIterations, in: container, debugDescription: "Warmup iterations cannot be negative")
        }
        guard Self.scalingFactors.contains(scalingFactor) else {
            throw DecodingError.dataCorruptedError(forKey: .scalingFactor, in: container, debugDescription: "Not one of ordo-one/benchmark's scaling factors")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(metric, forKey: .metric)
        try container.encode(timeUnits, forKey: .timeUnits)
        try container.encode(scalingFactor, forKey: .scalingFactor)
        try container.encode(warmupIterations, forKey: .warmupIterations)
        try container.encode([String: String](), forKey: .tags)
        try container.encode(statistics, forKey: .statistics)
    }
}
