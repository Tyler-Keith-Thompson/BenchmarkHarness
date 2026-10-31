import Foundation
import Histogram

/// The measurements of one metric over a benchmark's iterations, as ordo-one/benchmark stores them.
///
/// Values are recorded in an HDR histogram with three significant digits, the same configuration
/// ordo-one/benchmark uses, and encode with the same keys as its `Statistics`.
@frozen
public struct Statistics: Equatable, Sendable, Encodable {
    /// The display units ordo-one/benchmark derives from the magnitude of a mean.
    @frozen
    public enum Units: Int, Hashable, Sendable, Codable, CaseIterable {
        /// Below 10⁴.
        case count = 1
        /// From 10⁴ up to 10⁷.
        case kilo = 1_000
        /// From 10⁷ up to 10¹⁰.
        case mega = 1_000_000
        /// From 10¹⁰ up to 10¹³.
        case giga = 1_000_000_000
        /// From 10¹³ up to 10¹⁶.
        case tera = 1_000_000_000_000
        /// 10¹⁶ and above.
        case peta = 1_000_000_000_000_000

        /// The units for values whose mean is `mean`.
        ///
        /// - Parameter mean: A mean of non-negative values.
        public init(fromMagnitudeOf mean: Double) {
            switch mean.isFinite ? (mean > 0 ? log10(mean) : -.infinity) : .nan {
            case ..<4.0: self = .count
            case 4.0 ..< 7.0: self = .kilo
            case 7.0 ..< 10.0: self = .mega
            case 10.0 ..< 13.0: self = .giga
            case 13.0 ..< 16.0: self = .tera
            case 16.0...: self = .peta
            default: self = .kilo
            }
        }
    }

    /// The largest value the histogram tracks before resizing: one second in nanoseconds.
    public static let defaultMaximumMeasurement: UInt64 = 1_000_000_000

    /// The recorded measurements.
    public private(set) var histogram: Histogram<UInt>
    /// Whether larger values are better.
    public let prefersLarger: Bool

    /// The statistics of `measurements`.
    ///
    /// - Parameters:
    ///   - measurements: One value per iteration.
    ///   - prefersLarger: Whether larger values are better.
    /// - Complexity: O(*n*), where *n* is the number of measurements.
    public init(measurements: some Sequence<UInt64>, prefersLarger: Bool = false) {
        var histogram = Histogram<UInt>(
            highestTrackableValue: Self.defaultMaximumMeasurement,
            numberOfSignificantValueDigits: .three
        )
        histogram.autoResize = true
        for measurement in measurements {
            _ = histogram.record(measurement)
        }
        self.histogram = histogram
        self.prefersLarger = prefersLarger
    }

    /// The number of measurements recorded.
    @inlinable
    public var measurementCount: Int {
        Int(histogram.totalCount)
    }

    /// The units ordo-one/benchmark displays the measurements in: ``Units/count`` when every
    /// measurement is zero, otherwise the units for the magnitude of their mean.
    public var units: Units {
        histogram.countForValue(0) == histogram.totalCount ? .count : Units(fromMagnitudeOf: histogram.mean)
    }

    /// The measurement at `percentile`, from 0 to 100.
    ///
    /// - Complexity: O(*b*), where *b* is the number of histogram buckets.
    public func valueAtPercentile(_ percentile: Double) -> UInt64 {
        histogram.valueAtPercentile(percentile)
    }

    private enum CodingKeys: String, CodingKey {
        case cachedPercentiles = "_cachedPercentiles"
        case cacheUnits = "_cacheUnits"
        case cachedPercentilesHistogramCount = "_cachedPercentilesHistogramCount"
        case prefersLarger
        case timeUnits
        case histogram
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode([Int](), forKey: .cachedPercentiles)
        try container.encode(units.rawValue, forKey: .cacheUnits)
        try container.encode(histogram.totalCount, forKey: .cachedPercentilesHistogramCount)
        try container.encode(prefersLarger, forKey: .prefersLarger)
        // 0 is ordo-one/benchmark's `automatic`: the units follow the measurements.
        try container.encode(0, forKey: .timeUnits)
        try container.encode(histogram, forKey: .histogram)
    }
}
