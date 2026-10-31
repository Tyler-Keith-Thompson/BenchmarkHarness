/// A named set of benchmark results, in the file format of ordo-one/benchmark's stored baselines.
///
/// ordo-one/benchmark keeps one `results.json` per benchmark target and baseline name under the
/// package's `.benchmarkBaselines` directory (``relativePath(target:baselineName:)``). A baseline
/// written there is one its tool lists, compares (`swift package benchmark baseline compare`) and
/// checks thresholds against.
///
/// ```swift
/// let baseline = BenchmarkBaseline(
///     baselineName: "main",
///     machine: BenchmarkMachine(hostname: "guest", processors: 8, processorType: "aarch64",
///                               memory: 8, kernelVersion: "6.12.28"),
///     results: [
///         BenchmarkIdentifier(target: "SortBenchmarks", name: "Sort 1000"): [
///             BenchmarkResult(metric: .instructions, measurements: [206_978, 206_981],
///                             warmupIterations: 1),
///         ],
///     ]
/// )
/// let json = try JSONEncoder().encode(baseline)
/// ```
@frozen
public struct BenchmarkBaseline: Equatable, Sendable, Encodable {
    /// The baseline's name, such as `main`.
    public let baselineName: String
    /// The machine the results were measured on.
    public let machine: BenchmarkMachine
    /// The results of each benchmark, one per metric.
    public let results: [BenchmarkIdentifier: [BenchmarkResult]]

    /// A baseline holding `results`.
    ///
    /// - Parameters:
    ///   - baselineName: The baseline's name. Traps when empty or when it contains `/`.
    ///   - machine: The machine the results were measured on.
    ///   - results: The results of each benchmark, one per metric.
    public init(baselineName: String, machine: BenchmarkMachine, results: [BenchmarkIdentifier: [BenchmarkResult]]) {
        precondition(!baselineName.isEmpty && !baselineName.contains("/"), "A baseline name is one non-empty path component")
        self.baselineName = baselineName
        self.machine = machine
        self.results = results
    }

    /// The path, relative to a package's root, of the file ordo-one/benchmark reads for the
    /// baseline `baselineName` of benchmark target `target`.
    ///
    /// - Parameters:
    ///   - target: The benchmark executable target's name.
    ///   - baselineName: The baseline's name.
    /// - Returns: `.benchmarkBaselines/<target>/<baselineName>/results.json`.
    public static func relativePath(target: String, baselineName: String) -> String {
        ".benchmarkBaselines/\(target)/\(baselineName)/results.json"
    }

    /// The baselines ordo-one/benchmark stores per target: this baseline's results split by
    /// benchmark target, keyed by target name.
    public var byTarget: [String: BenchmarkBaseline] {
        Dictionary(grouping: results, by: \.key.target).mapValues { entries in
            BenchmarkBaseline(
                baselineName: baselineName,
                machine: machine,
                results: Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.value) })
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case baselineName
        case machine
        case results
    }

    /// Encodes the results as ordo-one/benchmark does a dictionary keyed by
    /// ``BenchmarkIdentifier``: an array alternating identifiers and their results, here sorted
    /// by target and name.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(baselineName, forKey: .baselineName)
        try container.encode(machine, forKey: .machine)
        var entries = container.nestedUnkeyedContainer(forKey: .results)
        for (identifier, metrics) in results.sorted(by: { $0.key < $1.key }) {
            try entries.encode(identifier)
            try entries.encode(metrics)
        }
    }
}

/// A benchmark, identified by its executable target and its name.
@frozen
public struct BenchmarkIdentifier: Hashable, Comparable, Sendable, Codable {
    /// The benchmark executable target's name.
    public let target: String
    /// The benchmark's name.
    public let name: String

    /// The benchmark `name` of executable target `target`.
    @inlinable
    public init(target: String, name: String) {
        self.target = target
        self.name = name
    }

    /// Orders by target, then by name.
    @inlinable
    public static func < (lhs: BenchmarkIdentifier, rhs: BenchmarkIdentifier) -> Bool {
        (lhs.target, lhs.name) < (rhs.target, rhs.name)
    }
}

/// The machine a baseline was measured on, as ordo-one/benchmark records it.
@frozen
public struct BenchmarkMachine: Hashable, Sendable, Codable {
    /// The machine's host name.
    public let hostname: String
    /// The number of processors.
    public let processors: Int
    /// The processor architecture, such as `arm64`.
    public let processorType: String
    /// The memory, in gigabytes.
    public let memory: Int
    /// The operating system kernel's version string.
    public let kernelVersion: String

    /// A machine description.
    @inlinable
    public init(hostname: String, processors: Int, processorType: String, memory: Int, kernelVersion: String) {
        self.hostname = hostname
        self.processors = processors
        self.processorType = processorType
        self.memory = memory
        self.kernelVersion = kernelVersion
    }
}
