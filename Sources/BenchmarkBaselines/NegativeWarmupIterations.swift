/// The error ``BenchmarkResult/init(metric:measurements:warmupIterations:)`` throws for a negative
/// warmup iteration count.
@frozen
public struct NegativeWarmupIterations: Error, Hashable, Sendable {
    @inlinable
    public init() {}
}
