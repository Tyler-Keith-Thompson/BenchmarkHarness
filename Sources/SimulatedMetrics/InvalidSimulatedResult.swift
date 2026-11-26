import BenchmarkBaselines

/// The error `BenchmarkResult(metric:iterations:overhead:warmupIterations:)` throws, one case per
/// input it rejects.
@frozen
public enum InvalidSimulatedResult: Error, Hashable, Sendable {
    /// A dump does not count one of ``SimulatedMetric/requiredEvents``.
    case missingRequiredEvent
    /// The warmup iteration count is negative.
    case negativeWarmupIterations
}
