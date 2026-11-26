import BenchmarkBaselines
import Callgrind

/// A metric computed from the events Callgrind counts while simulating the caches and branch
/// predictor.
///
/// Callgrind's counts depend only on the program and its input, not on how busy the machine is, so
/// these metrics repeat from run to run. Each maps to an ordo-one/benchmark metric
/// (``benchmarkMetric``): ``instructions`` to its built-in instruction count, the others to custom
/// metrics named as KCachegrind names the same derived events.
@frozen
public enum SimulatedMetric: Hashable, Sendable, CaseIterable {
    /// `Ir`: instructions executed.
    case instructions
    /// KCachegrind's *L1 Miss Sum*: `I1mr + D1mr + D1mw`.
    case level1MissSum
    /// KCachegrind's *Last-level Miss Sum*: `ILmr + DLmr + DLmw`.
    case lastLevelMissSum
    /// KCachegrind's *Mispredicted Branch*: `Bcm + Bim`.
    case mispredictedBranches
    /// KCachegrind's *Cycle Estimation*: `Ir + 10 Bm + 10 L1m + 100 LLm`, where `Bm`, `L1m` and
    /// `LLm` are ``mispredictedBranches``, ``level1MissSum`` and ``lastLevelMissSum``.
    case cycleEstimation

    /// The events a dump must count for every simulated metric: Callgrind's events with
    /// `--cache-sim=yes` and `--branch-sim=yes`, except data reads and writes and branches
    /// executed.
    public static let requiredEvents: Set<CallgrindEvent> = [
        .instructionCacheReads,
        .level1InstructionCacheReadMisses, .level1DataCacheReadMisses, .level1DataCacheWriteMisses,
        .lastLevelInstructionCacheReadMisses, .lastLevelDataCacheReadMisses, .lastLevelDataCacheWriteMisses,
        .conditionalBranchMispredictions, .indirectBranchMispredictions,
    ]

    /// The metric's value in `dump`.
    ///
    /// - Parameter dump: A dump counting every event in ``requiredEvents``.
    /// - Throws: ``MissingRequiredEvent`` when the dump does not count an event the metric reads.
    /// - Complexity: O(1).
    public func value(in dump: CallgrindDump) throws(MissingRequiredEvent) -> UInt64 {
        let totals = dump.totals
        func total(_ event: CallgrindEvent) throws(MissingRequiredEvent) -> UInt64 {
            guard let total = totals[event] else { throw MissingRequiredEvent() }
            return UInt64(total)
        }
        // Each case reads only its own events: a lookup that can throw is never dead code, so
        // reading all nine for every metric would cost each one the others' lookups.
        return switch self {
        case .instructions:
            try total(.instructionCacheReads)
        case .level1MissSum:
            try total(.level1InstructionCacheReadMisses) + total(.level1DataCacheReadMisses)
                + total(.level1DataCacheWriteMisses)
        case .lastLevelMissSum:
            try total(.lastLevelInstructionCacheReadMisses) + total(.lastLevelDataCacheReadMisses)
                + total(.lastLevelDataCacheWriteMisses)
        case .mispredictedBranches:
            try total(.conditionalBranchMispredictions) + total(.indirectBranchMispredictions)
        case .cycleEstimation:
            try total(.instructionCacheReads)
                + 10 * SimulatedMetric.mispredictedBranches.value(in: dump)
                + 10 * SimulatedMetric.level1MissSum.value(in: dump)
                + 100 * SimulatedMetric.lastLevelMissSum.value(in: dump)
        }
    }

    /// The ordo-one/benchmark metric the values are stored as.
    public var benchmarkMetric: BenchmarkMetric {
        switch self {
        case .instructions: .instructions
        case .level1MissSum: .custom("L1 Miss Sum")
        case .lastLevelMissSum: .custom("Last-level Miss Sum")
        case .mispredictedBranches: .custom("Mispredicted Branch")
        case .cycleEstimation: .custom("Cycle Estimation")
        }
    }
}

extension BenchmarkResult {
    /// The result of `metric` over a benchmark's measured iterations, one Callgrind dump each, less
    /// the overhead of measuring.
    ///
    /// Each measured window also counts the work of opening and closing it. `overhead` holds dumps
    /// of windows opened and closed around nothing; their median value is subtracted from each
    /// iteration's, and a difference below zero is recorded as zero.
    ///
    /// - Parameters:
    ///   - metric: The simulated metric.
    ///   - iterations: One dump per measured iteration.
    ///   - overhead: Dumps of empty measurement windows; when empty, nothing is subtracted.
    ///   - warmupIterations: The iterations run before measuring began.
    /// - Throws: ``InvalidSimulatedResult/missingRequiredEvent`` when a dump does not count an
    ///   event `metric` reads (one of ``SimulatedMetric/requiredEvents``), and
    ///   ``InvalidSimulatedResult/negativeWarmupIterations`` when `warmupIterations` is negative.
    /// - Complexity: O(*n* + *m* log *m*), where *n* is the number of iterations and *m* the
    ///   number of overhead dumps.
    public init(
        metric: SimulatedMetric, iterations: [CallgrindDump], overhead: [CallgrindDump], warmupIterations: Int
    ) throws(InvalidSimulatedResult) {
        let measurements: [UInt64]
        do {
            let overheadValues = try overhead.map(metric.value(in:)).sorted()
            let median = overheadValues.isEmpty ? 0 : overheadValues[(overheadValues.count - 1) / 2]
            measurements = try iterations.map { dump throws(MissingRequiredEvent) in
                let value = try metric.value(in: dump)
                return value > median ? value - median : 0
            }
        } catch {
            throw .missingRequiredEvent
        }
        do {
            try self.init(metric: metric.benchmarkMetric, measurements: measurements, warmupIterations: warmupIterations)
        } catch {
            throw .negativeWarmupIterations
        }
    }
}
