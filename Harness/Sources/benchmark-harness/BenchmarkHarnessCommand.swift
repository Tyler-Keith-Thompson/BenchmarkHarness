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
        abstract: "Measure the package's benchmarks under Callgrind in a Linux virtual machine and store the results as an ordo-one/benchmark baseline.",
        discussion: """
            Compare baselines with ordo-one/benchmark's own tool, for example:
              swift package benchmark baseline compare main pull-request
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

    @Option(help: "The virtual machine's processors.")
    var cpus: Int = 4

    @Option(help: "The virtual machine's memory, in GiB.")
    var memory: Int = 8

    @Option(help: "Where downloads, images and build products are cached.")
    var cachePath: String = SimulatedBaselineRecorder.defaultCachePath.path

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
        let baseline = try await recorder.record()
        print("Wrote baseline '\(baseline.baselineName)' for \(baseline.results.count) benchmarks")
    }
}
