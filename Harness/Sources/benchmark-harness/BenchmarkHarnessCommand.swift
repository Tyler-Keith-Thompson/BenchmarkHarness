import ArgumentParser
import Foundation
import HarnessHost

@main
struct BenchmarkHarnessCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "benchmark-harness",
        abstract: "Measure ordo-one/benchmark benchmarks from simulated hardware counts that do not depend on how busy the machine is.",
        subcommands: [Baseline.self]
    )
}

struct Baseline: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Record benchmark baselines.",
        subcommands: [Update.self]
    )
}

struct Update: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Measure the package's benchmarks under Callgrind on Linux (a virtual machine on macOS, the host itself on Linux) and store the results as an ordo-one/benchmark baseline.",
        discussion: """
            Compare baselines with ordo-one/benchmark's own tool, for example:
              swift package benchmark baseline compare main pull-request

            The run stops, ending its benchmark processes and virtual machine, on SIGINT, SIGTERM
            or SIGHUP, and when the process that started it exits.
            """
    )

    @Argument(help: "The name of the baseline to write.")
    var baselineName: String

    @Option(help: "The package whose benchmarks to measure.")
    var packagePath: String = FileManager.default.currentDirectoryPath

    @Option(name: .customLong("target"), help: "A benchmark target to measure; all when omitted. Repeatable.")
    var targets: [String] = []

    @Option(name: .customLong("filter"), help: "Run only benchmarks whose name matches this regular expression. Repeatable.")
    var filters: [String] = []

    @Option(name: .customLong("skip"), help: "Skip benchmarks whose name matches this regular expression. Repeatable.")
    var skips: [String] = []

    @Option(help: "The virtual machine's processors (macOS only).")
    var cpus: Int = 4

    @Option(help: "The virtual machine's memory, in GiB (macOS only).")
    var memory: Int = 16

    @Option(help: "Benchmarks measured at once (default: --cpus on macOS, the host's processors on Linux); the counts don't depend on load.")
    var jobs: Int?

    @Option(help: "Measured iterations per benchmark (fewer if its own maxIterations is lower), in place of its wall-clock limit.")
    var iterations: Int = 3

    @Option(help: "Where downloads, images and build products are cached.")
    var cachePath: String = SimulatedBaselineRecorder.defaultCachePath.path

    func validate() throws {
        guard cpus > 0 else { throw ValidationError("--cpus must be at least 1.") }
        guard (jobs ?? 1) > 0 else { throw ValidationError("--jobs must be at least 1.") }
        guard iterations > 0 else { throw ValidationError("--iterations must be at least 1.") }
    }

    func run() async throws {
        var recorder = SimulatedBaselineRecorder(
            packagePath: URL(fileURLWithPath: packagePath),
            baselineName: baselineName,
            cachePath: URL(fileURLWithPath: cachePath)
        )
        recorder.targets = targets
        recorder.filters = filters
        recorder.skips = skips
        recorder.cpus = cpus
        recorder.memoryGiB = memory
        recorder.iterations = iterations
        #if os(Linux)
        recorder.jobs = jobs ?? ProcessInfo.processInfo.activeProcessorCount
        #else
        recorder.jobs = jobs ?? cpus
        #endif
        let configured = recorder
        let baseline = try await runUntilInterrupted { try await configured.record() }
        print("Wrote baseline '\(baseline.baselineName)' for \(baseline.results.count) benchmarks")
    }
}
