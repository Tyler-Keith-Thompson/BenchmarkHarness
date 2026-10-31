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
    /// - Parameter dump: A dump counting every event in ``requiredEvents``. Traps otherwise.
    /// - Complexity: O(1).
    public func value(in dump: CallgrindDump) -> UInt64 {
        let level1 = dump[.level1InstructionCacheReadMisses] + dump[.level1DataCacheReadMisses]
            + dump[.level1DataCacheWriteMisses]
        let lastLevel = dump[.lastLevelInstructionCacheReadMisses] + dump[.lastLevelDataCacheReadMisses]
            + dump[.lastLevelDataCacheWriteMisses]
        let branches = dump[.conditionalBranchMispredictions] + dump[.indirectBranchMispredictions]
        let value = switch self {
        case .instructions: dump[.instructionCacheReads]
        case .level1MissSum: level1
        case .lastLevelMissSum: lastLevel
        case .mispredictedBranches: branches
        case .cycleEstimation: dump[.instructionCacheReads] + 10 * branches + 10 * level1 + 100 * lastLevel
        }
        return UInt64(value)
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
    ///   - warmupIterations: The iterations run before measuring began. Traps when negative.
    ///
    ///   Every dump must count each event in ``SimulatedMetric/requiredEvents``; traps otherwise.
    /// - Complexity: O(*n* + *m* log *m*), where *n* is the number of iterations and *m* the
    ///   number of overhead dumps.
    public init(metric: SimulatedMetric, iterations: [CallgrindDump], overhead: [CallgrindDump], warmupIterations: Int) {
        let overheadValues = overhead.map(metric.value(in:)).sorted()
        let median = overheadValues.isEmpty ? 0 : overheadValues[(overheadValues.count - 1) / 2]
        self.init(
            metric: metric.benchmarkMetric,
            measurements: iterations.map { dump in
                let value = metric.value(in: dump)
                return value > median ? value - median : 0
            },
            warmupIterations: warmupIterations
        )
    }
}
