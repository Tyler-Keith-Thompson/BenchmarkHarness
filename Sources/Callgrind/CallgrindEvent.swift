/// An event Callgrind counts, named by the abbreviation its output files use.
///
/// The static members are the events Callgrind records with `--cache-sim=yes` and
/// `--branch-sim=yes`; their names follow the Valgrind manual's descriptions. Any other
/// abbreviation is representable too, so a dump from other options still parses.
@frozen
public struct CallgrindEvent: RawRepresentable, Hashable, Sendable {
    /// The abbreviation in a dump's `events:` line, such as `Ir`.
    public var rawValue: String

    /// The event with abbreviation `rawValue`.
    @inlinable
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// `Ir`: instruction cache reads, one per instruction executed.
    public static let instructionCacheReads = CallgrindEvent(rawValue: "Ir")
    /// `Dr`: data cache reads, one per memory read.
    public static let dataCacheReads = CallgrindEvent(rawValue: "Dr")
    /// `Dw`: data cache writes, one per memory write.
    public static let dataCacheWrites = CallgrindEvent(rawValue: "Dw")
    /// `I1mr`: first-level instruction cache read misses.
    public static let level1InstructionCacheReadMisses = CallgrindEvent(rawValue: "I1mr")
    /// `D1mr`: first-level data cache read misses.
    public static let level1DataCacheReadMisses = CallgrindEvent(rawValue: "D1mr")
    /// `D1mw`: first-level data cache write misses.
    public static let level1DataCacheWriteMisses = CallgrindEvent(rawValue: "D1mw")
    /// `ILmr`: last-level cache misses on instruction reads.
    public static let lastLevelInstructionCacheReadMisses = CallgrindEvent(rawValue: "ILmr")
    /// `DLmr`: last-level cache misses on data reads.
    public static let lastLevelDataCacheReadMisses = CallgrindEvent(rawValue: "DLmr")
    /// `DLmw`: last-level cache misses on data writes.
    public static let lastLevelDataCacheWriteMisses = CallgrindEvent(rawValue: "DLmw")
    /// `Bc`: conditional branches executed.
    public static let conditionalBranches = CallgrindEvent(rawValue: "Bc")
    /// `Bcm`: conditional branches mispredicted.
    public static let conditionalBranchMispredictions = CallgrindEvent(rawValue: "Bcm")
    /// `Bi`: indirect branches executed.
    public static let indirectBranches = CallgrindEvent(rawValue: "Bi")
    /// `Bim`: indirect branches mispredicted.
    public static let indirectBranchMispredictions = CallgrindEvent(rawValue: "Bim")
}
