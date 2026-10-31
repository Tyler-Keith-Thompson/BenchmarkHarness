/// A metric of an ordo-one/benchmark result: one of ordo-one/benchmark's built-in metrics, or a
/// custom metric.
///
/// The cases are ordo-one/benchmark 1.38's `BenchmarkMetric` cases, and encode exactly as it
/// encodes them, so a baseline holding them is one ordo-one's tool reads, compares and checks
/// thresholds against, and results an executable reports decode to them.
@frozen
public enum BenchmarkMetric: Hashable, Sendable, Codable {
    /// CPU time spent in user mode.
    case cpuUser
    /// CPU time spent in the kernel.
    case cpuSystem
    /// CPU time in user mode and the kernel together.
    case cpuTotal
    /// Elapsed wall-clock time.
    case wallClock
    /// Iterations per second.
    case throughput
    /// The peak resident memory.
    case peakMemoryResident
    /// The change in peak resident memory.
    case peakMemoryResidentDelta
    /// The peak virtual memory.
    case peakMemoryVirtual
    /// Allocations of a small size class.
    case mallocCountSmall
    /// Allocations of a large size class.
    case mallocCountLarge
    /// All allocations.
    case mallocCountTotal
    /// All frees.
    case freeCountTotal
    /// The bytes allocated.
    case mallocBytesCount
    /// Allocations less frees.
    case mallocFreeDelta
    /// The resident memory the allocator holds.
    case allocatedResidentMemory
    /// Allocations never freed.
    case memoryLeaked
    /// The bytes of allocations never freed.
    case memoryLeakedBytes
    /// System calls.
    case syscalls
    /// Context switches.
    case contextSwitches
    /// Threads.
    case threads
    /// Threads running.
    case threadsRunning
    /// Read system calls.
    case readSyscalls
    /// Write system calls.
    case writeSyscalls
    /// Bytes read, as requested.
    case readBytesLogical
    /// Bytes written, as requested.
    case writeBytesLogical
    /// Bytes read from storage.
    case readBytesPhysical
    /// Bytes written to storage.
    case writeBytesPhysical
    /// The number of instructions executed.
    case instructions
    /// Swift objects allocated.
    case objectAllocCount
    /// Swift retains.
    case retainCount
    /// Swift releases.
    case releaseCount
    /// Swift retains less releases.
    case retainReleaseDelta
    /// A metric ordo-one/benchmark does not define, identified by its name.
    ///
    /// - Parameters:
    ///   - name: The name the tool prints and matches thresholds against.
    ///   - polarity: Whether smaller or larger values are better.
    ///   - useScalingFactor: Whether values are divided by the benchmark's scaling factor.
    case custom(_ name: String, polarity: Polarity = .prefersSmaller, useScalingFactor: Bool = true)
    /// The difference between two results, which ordo-one/benchmark's tool computes.
    case delta
    /// The difference between two results as a percentage, which ordo-one/benchmark's tool
    /// computes.
    case deltaPercentage

    /// Whether smaller or larger values of a metric are better.
    @frozen
    public enum Polarity: Hashable, Sendable, Codable {
        /// Larger values are better, as for throughput.
        case prefersLarger
        /// Smaller values are better, as for time and counts of work.
        case prefersSmaller
    }

    /// Whether larger values of the metric are better: true for ``throughput`` and for a
    /// ``custom(_:polarity:useScalingFactor:)`` metric that prefers larger values.
    @inlinable
    public var prefersLarger: Bool {
        switch self {
        case .throughput: true
        case let .custom(_, polarity, _): polarity == .prefersLarger
        default: false
        }
    }
}
