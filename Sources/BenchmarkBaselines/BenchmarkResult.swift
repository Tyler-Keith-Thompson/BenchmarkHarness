/// The measurements of one metric of one benchmark, as ordo-one/benchmark stores them in a baseline.
@frozen
public struct BenchmarkResult: Equatable, Sendable, Encodable {
    /// The metric measured.
    public let metric: BenchmarkMetric
    /// The measurements, one per iteration.
    public let statistics: Statistics
    /// The iterations run before measuring began.
    public let warmupIterations: Int

    /// The result of measuring `metric` once per iteration.
    ///
    /// - Parameters:
    ///   - metric: The metric measured.
    ///   - measurements: One value per measured iteration.
    ///   - warmupIterations: The iterations run before measuring began. Traps when negative.
    /// - Complexity: O(*n*), where *n* is the number of measurements.
    public init(metric: BenchmarkMetric, measurements: some Sequence<UInt64>, warmupIterations: Int) {
        precondition(warmupIterations >= 0, "Warmup iterations cannot be negative")
        self.metric = metric
        self.statistics = Statistics(measurements: measurements, prefersLarger: metric.prefersLarger)
        self.warmupIterations = warmupIterations
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

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(metric, forKey: .metric)
        try container.encode(timeUnits, forKey: .timeUnits)
        // 1 is ordo-one/benchmark's `BenchmarkScalingFactor.one`: values are per iteration.
        try container.encode(1, forKey: .scalingFactor)
        try container.encode(warmupIterations, forKey: .warmupIterations)
        try container.encode([String: String](), forKey: .tags)
        try container.encode(statistics, forKey: .statistics)
    }
}
