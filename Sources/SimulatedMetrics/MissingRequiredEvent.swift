/// The error ``SimulatedMetric/value(in:)`` throws for a dump that does not count one of
/// ``SimulatedMetric/requiredEvents``.
@frozen
public struct MissingRequiredEvent: Error, Hashable, Sendable {
    @inlinable
    public init() {}
}
