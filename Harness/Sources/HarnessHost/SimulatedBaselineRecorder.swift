import BenchmarkBaselines
import BenchmarkCommands
import Callgrind
import CryptoKit
import Foundation
import SimulatedMetrics

/// Records an ordo-one/benchmark baseline of a package's benchmarks from Callgrind's simulated
/// counts, measured in a Linux guest.
///
/// The package's benchmark targets are built in the guest and each benchmark executable is run
/// under Callgrind, driven by ordo-one/benchmark's own protocol, so benchmarks are declared and
/// configured exactly as for `swift package benchmark`. Each measured iteration is one Callgrind
/// dump; the result of each ``SimulatedMetric`` is written to the package's `.benchmarkBaselines`
/// directory, where ordo-one/benchmark's tool compares it with other baselines.
public struct SimulatedBaselineRecorder: Sendable {
    /// The package whose benchmarks are measured.
    public var packagePath: URL
    /// The name of the baseline written.
    public var baselineName: String
    /// The benchmark targets to measure; all when empty.
    public var targets: [String] = []
    /// Regular expressions; when any are given, only benchmarks whose name matches one are run.
    public var filters: [String] = []
    /// Regular expressions; benchmarks whose name matches one are skipped.
    public var skips: [String] = []
    /// Where downloads, the guest's images, the Valgrind build and build products are kept.
    public var cachePath: URL
    /// The guest's virtual processors.
    public var cpus: Int = 4
    /// The guest's memory, in gibibytes.
    public var memoryGiB: Int = 8

    /// A recorder for the package at `packagePath`.
    public init(packagePath: URL, baselineName: String, cachePath: URL) {
        self.packagePath = packagePath
        self.baselineName = baselineName
        self.cachePath = cachePath
    }

    /// The default cache: `~/Library/Caches/BenchmarkHarness`.
    public static var defaultCachePath: URL {
        URL.cachesDirectory.appending(path: "BenchmarkHarness")
    }

    /// Measures the benchmarks and writes the baseline, one `results.json` per target.
    ///
    /// - Returns: The baseline written.
    public func record() async throws -> BenchmarkBaseline {
        let filters = try self.filters.map { try Regex($0) }
        let skips = try self.skips.map { try Regex($0) }
        let package = packagePath.standardizedFileURL.resolvingSymlinksInPath()
        let sourceRoot = Self.sourceRoot(of: package)
        let relativePackage = String(package.path.dropFirst(sourceRoot.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let guestPackage = relativePackage.isEmpty ? "/work" : "/work/\(relativePackage)"

        let shared = cachePath.appending(path: "guest")
        let files = shared.appending(path: "files")
        let dumpsRoot = shared.appending(path: "dumps")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try Self.installGuestFiles(into: files)

        let kernel = try await Self.kernel(in: cachePath)
        let valgrindSource = try await PinnedDownload.valgrindSource.fetch(into: shared.appending(path: "downloads"))
        let patch = try Data(contentsOf: files.appending(path: "valgrind-rt_sigsuspend.patch"))
        let valgrindArchive = "valgrind-3.28.0-\(Self.digest(patch).prefix(12)).tar"
        let scratch = "/harness/scratch/\(Self.digest(Data(sourceRoot.path.utf8)).prefix(16))"

        let socket = FileManager.default.temporaryDirectory.appending(path: "bh-\(ProcessInfo.processInfo.processIdentifier).sock").path
        let proxy = try await ConnectProxy.start(socketPath: socket)
        let guest: GuestMachine
        do {
            guest = try await GuestMachine.boot(
                kernel: kernel,
                store: cachePath.appending(path: "store"),
                cpus: cpus,
                memoryInBytes: UInt64(memoryGiB) << 30,
                shares: [
                    .init(hostPath: shared, guestPath: "/harness", readOnly: false),
                    .init(hostPath: sourceRoot, guestPath: "/source", readOnly: true),
                ],
                proxySocket: socket,
                bridge: "/harness/files/proxy-bridge.pl"
            )
        } catch {
            await proxy.stop()
            throw error
        }
        do {
            let baseline = try await measure(
                in: guest,
                package: package,
                guestPackage: guestPackage,
                scratch: scratch,
                valgrindSource: "/harness/downloads/\(valgrindSource.lastPathComponent)",
                valgrindArchive: "/harness/\(valgrindArchive)",
                dumpsRoot: dumpsRoot,
                filters: filters,
                skips: skips
            )
            await guest.shutdown()
            await proxy.stop()
            return baseline
        } catch {
            await guest.shutdown()
            await proxy.stop()
            throw error
        }
    }

    private func measure(
        in guest: GuestMachine,
        package: URL,
        guestPackage: String,
        scratch: String,
        valgrindSource: String,
        valgrindArchive: String,
        dumpsRoot: URL,
        filters: [Regex<AnyRegexOutput>],
        skips: [Regex<AnyRegexOutput>]
    ) async throws -> BenchmarkBaseline {
        let proxy = GuestMachine.proxyEnvironment
        try await guest.check(["/bin/bash", "/harness/files/provision.sh", valgrindSource, valgrindArchive, "/harness/files"], environment: proxy)
        try await guest.check(["/bin/bash", "/harness/files/stage.sh", "/source", "/work"])

        let manifest = try await guest.output(["swift", "package", "dump-package", "--package-path", guestPackage])
        let available = try Self.benchmarkTargets(inManifest: manifest)
        let selected = targets.isEmpty ? available : available.filter(targets.contains)
        guard !selected.isEmpty else { throw NoBenchmarkTargets(available: available) }

        let build = ["swift", "build", "-c", "release", "--package-path", guestPackage, "--scratch-path", scratch]
        for target in selected {
            FileHandle.standardError.write(Data("Building \(target)\n".utf8))
            try await guest.check(build + ["--product", target], environment: proxy)
        }
        let binPath = String(decoding: try await guest.output(build + ["--show-bin-path"]), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let kernelVersion = String(decoding: try await guest.output(["uname", "-r"]), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var results: [BenchmarkIdentifier: [BenchmarkResult]] = [:]
        for target in selected {
            let measured = try await measureTarget(
                target,
                executable: "\(binPath)/\(target)",
                in: guest,
                dumps: dumpsRoot.appending(path: target),
                filters: filters,
                skips: skips
            )
            results.merge(measured) { first, _ in first }
        }

        let baseline = BenchmarkBaseline(
            baselineName: baselineName,
            machine: BenchmarkMachine(
                hostname: "benchmark-harness",
                processors: cpus,
                processorType: "aarch64 (Callgrind 3.28.0 simulation)",
                memory: memoryGiB,
                kernelVersion: "Linux \(kernelVersion)"
            ),
            results: results
        )
        let encoder = JSONEncoder()
        for (target, perTarget) in baseline.byTarget.sorted(by: { $0.key < $1.key }) {
            let file = package.appending(path: BenchmarkBaseline.relativePath(target: target, baselineName: baselineName))
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(perTarget).write(to: file, options: .atomic)
        }
        return baseline
    }

    private func measureTarget(
        _ target: String,
        executable: String,
        in guest: GuestMachine,
        dumps: URL,
        filters: [Regex<AnyRegexOutput>],
        skips: [Regex<AnyRegexOutput>]
    ) async throws -> [BenchmarkIdentifier: [BenchmarkResult]] {
        let (requests, requestContinuation) = AsyncStream.makeStream(of: Data.self)
        let (replies, replyContinuation) = AsyncStream.makeStream(of: Data.self)
        let guestDumps = "/harness/dumps/\(target)"
        async let exitCode = guest.run(
            ["/bin/bash", "/harness/files/run-benchmarks.sh", executable, guestDumps],
            standardInput: StreamReader(source: requests),
            standardOutput: StreamWriter(continuation: replyContinuation)
        )
        var channel = BenchmarkChannel(input: requestContinuation, output: replies)
        var results: [BenchmarkIdentifier: [BenchmarkResult]] = [:]
        do {
            channel.send(.list)
            var benchmarks: [Benchmark] = []
            listing: while true {
                switch try await channel.receive() {
                case let .list(benchmark): benchmarks.append(benchmark)
                case .end: break listing
                case let .error(description): throw BenchmarkFailed(target: target, benchmark: nil, description: description)
                default: continue
                }
            }
            let chosen = benchmarks.filter { benchmark in
                (filters.isEmpty || filters.contains { benchmark.name.firstMatch(of: $0) != nil })
                    && !skips.contains { benchmark.name.firstMatch(of: $0) != nil }
            }
            var consumed = 0
            for benchmark in chosen {
                FileHandle.standardError.write(Data("Measuring \(target): \(benchmark.name)\n".utf8))
                channel.send(.run(benchmark: benchmark.measuring([.instructions])))
                running: while true {
                    switch try await channel.receive() {
                    case .end: break running
                    case let .error(description): throw BenchmarkFailed(target: target, benchmark: benchmark.name, description: description)
                    default: continue
                    }
                }
                let (dumpsRead, iterations, overhead) = try Self.readDumps(in: dumps, after: consumed)
                consumed = dumpsRead
                let identifier = BenchmarkIdentifier(target: target, name: benchmark.name)
                results[identifier] = SimulatedMetric.allCases.map { metric in
                    BenchmarkResult(metric: metric, iterations: iterations, overhead: overhead, warmupIterations: benchmark.warmupIterations)
                }
                Self.report(identifier, iterations: iterations, overhead: overhead, results: results[identifier] ?? [])
            }
            channel.send(.end)
            channel.finish()
        } catch {
            channel.finish()
            _ = try? await exitCode
            throw error
        }
        let code = try await exitCode
        guard code == 0 else {
            throw BenchmarkFailed(target: target, benchmark: nil, description: "The executable exited with code \(code); see \(dumps.appending(path: "valgrind.log").path)")
        }
        return results
    }

    /// Reads the dumps numbered after `consumed`, split into measured iterations and calibration
    /// windows, and deletes them.
    private static func readDumps(in directory: URL, after consumed: Int) throws -> (Int, [CallgrindDump], [CallgrindDump]) {
        let numbered = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .compactMap { name -> (Int, String)? in
                guard name.hasPrefix("callgrind.out."), let number = Int(name.dropFirst("callgrind.out.".count)) else { return nil }
                return (number, name)
            }
            .filter { $0.0 > consumed }
            .sorted { $0.0 < $1.0 }
        var iterations: [CallgrindDump] = []
        var overhead: [CallgrindDump] = []
        for (_, name) in numbered {
            let file = directory.appending(path: name)
            let dump = try CallgrindDump(checkedText: String(decoding: try Data(contentsOf: file), as: UTF8.self))
            guard SimulatedMetric.requiredEvents.isSubset(of: Set(dump.events)) else { throw MalformedCallgrindDump() }
            switch dump.trigger {
            case "Client Request: iteration": iterations.append(dump)
            case "Client Request: calibration": overhead.append(dump)
            default: break
            }
            try? FileManager.default.removeItem(at: file)
        }
        return (numbered.last?.0 ?? consumed, iterations, overhead)
    }

    private static func report(_ identifier: BenchmarkIdentifier, iterations: [CallgrindDump], overhead: [CallgrindDump], results: [BenchmarkResult]) {
        let values = zip(SimulatedMetric.allCases, results).map { metric, result in
            "\(metric.benchmarkMetric.name) \(result.statistics.valueAtPercentile(50))"
        }
        let overheadInstructions = overhead.map { SimulatedMetric.instructions.value(in: $0) }.sorted()
        let windowCost = overheadInstructions.isEmpty ? 0 : overheadInstructions[(overheadInstructions.count - 1) / 2]
        print("\(identifier.target): \(identifier.name) (\(iterations.count) iterations, p50, less \(windowCost) instructions of measuring) — \(values.joined(separator: ", "))")
    }

    /// The benchmark targets in a `swift package dump-package` manifest: executable targets that
    /// use a plugin named `BenchmarkPlugin`, ordo-one/benchmark's, sorted by name.
    ///
    /// - Throws: ``MalformedManifest`` when `manifest` has no target list.
    package static func benchmarkTargets(inManifest manifest: Data) throws -> [String] {
        struct Manifest: Decodable {
            struct Target: Decodable {
                struct PluginUsage: Decodable {
                    let plugin: [String?]?
                }

                let name: String
                let type: String
                let pluginUsages: [PluginUsage]?
            }

            let targets: [Target]
        }
        guard let decoded = try? JSONDecoder().decode(Manifest.self, from: manifest) else {
            throw MalformedManifest()
        }
        return decoded.targets
            .filter { target in
                target.type == "executable" && (target.pluginUsages ?? []).contains { $0.plugin?.first == "BenchmarkPlugin" }
            }
            .map(\.name)
            .sorted()
    }

    /// The root of the source tree to share: the enclosing Git work tree, so path dependencies
    /// outside the package resolve, or the package itself.
    private static func sourceRoot(of package: URL) -> URL {
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", package.path, "rev-parse", "--show-toplevel"]
        let pipe = Pipe()
        git.standardOutput = pipe
        git.standardError = FileHandle.nullDevice
        guard (try? git.run()) != nil else { return package }
        git.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard git.terminationStatus == 0, !output.isEmpty else { return package }
        return URL(fileURLWithPath: output).standardizedFileURL.resolvingSymlinksInPath()
    }

    /// The guest kernel, extracted once from the pinned Kata Containers release.
    private static func kernel(in cache: URL) async throws -> URL {
        let kernel = cache.appending(path: "kernel/vmlinux-6.12.28-153")
        if FileManager.default.fileExists(atPath: kernel.path) { return kernel }
        let archive = try await PinnedDownload.kataContainers.fetch(into: cache.appending(path: "downloads"))
        let directory = kernel.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let member = "./opt/kata/share/kata-containers/vmlinux-6.12.28-153"
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xJf", archive.path, "-C", directory.path, "--strip-components", "5", member]
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0, FileManager.default.fileExists(atPath: kernel.path) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: archive.path])
        }
        return kernel
    }

    /// Copies the scripts and sources the guest runs onto the shared volume.
    private static func installGuestFiles(into directory: URL) throws {
        guard let resources = Bundle.module.url(forResource: "Guest", withExtension: nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.copyItem(at: resources, to: directory)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension BenchmarkMetric {
    /// The name ordo-one/benchmark prints for the metric.
    var name: String {
        switch self {
        case .instructions: "Instructions"
        case let .custom(name, _, _): name
        }
    }
}

/// The error thrown when no benchmark target is selected.
public struct NoBenchmarkTargets: Error, CustomStringConvertible, Sendable {
    /// The package's benchmark targets.
    public let available: [String]

    public var description: String {
        available.isEmpty
            ? "The package has no executable targets using ordo-one/benchmark's BenchmarkPlugin"
            : "No benchmark target selected; the package has \(available.joined(separator: ", "))"
    }
}

/// The error thrown when a benchmark executable reports a failure.
public struct BenchmarkFailed: Error, CustomStringConvertible, Sendable {
    /// The benchmark target.
    public let target: String
    /// The benchmark, when the failure was running one.
    public let benchmark: String?
    /// What the executable reported.
    public let description: String
}

/// The error thrown for a `swift package dump-package` manifest without a target list.
public struct MalformedManifest: Error, Hashable, Sendable {
    public init() {}
}
