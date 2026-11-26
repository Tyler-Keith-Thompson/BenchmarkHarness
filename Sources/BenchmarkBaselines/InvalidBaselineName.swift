/// The error ``BenchmarkBaseline/init(baselineName:machine:results:)`` throws for a name that is not
/// one non-empty path component.
@frozen
public struct InvalidBaselineName: Error, Hashable, Sendable {
    @inlinable
    public init() {}
}
