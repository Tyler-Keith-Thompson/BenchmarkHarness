import BenchmarkBaselines
import BenchmarkCommands
import Callgrind
import Crypto
import Foundation
import SimulatedMetrics

/// Records an ordo-one/benchmark baseline of a package's benchmarks from Callgrind's simulated
/// counts, measured on Linux: in a guest booted on macOS, or on the Linux host itself.
///
/// The package's benchmark targets are built on that machine and each benchmark executable is run
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
    /// The guest's virtual processors, on macOS.
    public var cpus: Int = 4
    /// The guest's memory, in gibibytes, on macOS.
    public var memoryGiB: Int = 16
    /// The iterations of each benchmark that are measured.
    ///
    /// Simulated counts don't depend on time, so a benchmark's own wall-clock limit doesn't apply:
    /// it measures exactly this many iterations, or its own `maxIterations` if fewer, however busy
    /// the machine is. Its own warmup iterations still run first. Three let the median discard
    /// the first, coldest iteration.
    public var iterations: Int = 3
    /// The benchmark targets measured at once, each in its own Callgrind process.
    ///
    /// Callgrind runs a process's threads one at a time, so separate targets are what use the
    /// guest's processors. Simulated counts don't depend on load, so this changes no result.
    public var jobs: Int = 4

    /// A recorder for the package at `packagePath`.
    public init(packagePath: URL, baselineName: String, cachePath: URL) {
        self.packagePath = packagePath
        self.baselineName = baselineName
        self.cachePath = cachePath
    }

    /// The default cache: `BenchmarkHarness` in the user's caches directory, `~/Library/Caches` on
    /// macOS and `~/.cache` on Linux.
    public static var defaultCachePath: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cache")
        return caches.appending(path: "BenchmarkHarness")
    }

    /// Measures the benchmarks and writes the baseline, one `results.json` per target.
    ///
    /// On macOS the benchmarks run in a Linux guest; on Linux, on the host itself.
    ///
    /// - Returns: The baseline written.
    public func record() async throws -> BenchmarkBaseline {
        // Compiled here only to reject a bad pattern before booting; each target compiles its own,
        // because a Regex can't cross into the tasks that measure targets concurrently.
        _ = try self.filters.map { try Regex($0) }
        _ = try self.skips.map { try Regex($0) }
        let package = packagePath.standardizedFileURL.resolvingSymlinksInPath()
        let sourceRoot = Self.sourceRoot(of: package)

        let shared = cachePath.appending(path: "guest")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        // Runs on the same checkout share its staged copy and build products, so they take turns;
        // runs on other checkouts go on at the same time.
        let lock = try await CheckoutLock(file: shared.appending(path: "locks/\(Self.digest(Data(sourceRoot.path.utf8)).prefix(16)).lock")) { holder in
            let process = holder.map { " (process \($0))" } ?? ""
            FileHandle.standardError.write(Data("Waiting for another run on \(sourceRoot.path)\(process)\n".utf8))
        }
        defer { withExtendedLifetime(lock) {} }
        let files = try Self.installGuestFiles(in: shared)
        // Each run has its own dumps, so concurrent runs never read each other's.
        let run = "\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(8))"
        let dumpsRoot = shared.appending(path: "dumps").appending(path: run)
        let valgrindSource = try await PinnedDownload.valgrindSource.fetch(into: shared.appending(path: "downloads"))
        let patch = try Data(contentsOf: files.appending(path: "valgrind.patch"))
        let valgrindBuild = "valgrind-3.28.0-\(Self.digest(patch).prefix(12))"

        #if os(macOS)
        let layout = Layout(shared: "/harness", source: "/source", work: "/work", prefix: "/opt")
        let kernel = try await Self.kernel(in: cachePath)
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
                    .init(hostPath: shared, guestPath: layout.shared, readOnly: false),
                    .init(hostPath: sourceRoot, guestPath: layout.source, readOnly: true),
                ],
                proxySocket: socket,
                bridge: "\(layout.shared)/\(files.lastPathComponent)/proxy-bridge.pl"
            )
        } catch {
            await proxy.stop()
            throw error
        }
        do {
            let baseline = try await measure(
                on: guest,
                layout: layout,
                processors: cpus,
                memoryGiB: memoryGiB,
                package: package,
                sourceRoot: sourceRoot,
                files: files,
                valgrindSource: valgrindSource,
                valgrindBuild: valgrindBuild,
                run: run,
                dumpsRoot: dumpsRoot
            )
            await guest.shutdown()
            await proxy.stop()
            return baseline
        } catch {
            await guest.shutdown()
            await proxy.stop()
            throw error
        }
        #else
        // The host's own paths. Valgrind is installed under the cache, once per build of it, and
        // the checkout is staged by the digest of its path, so its builds stay incremental.
        let layout = Layout(
            shared: shared.path,
            source: sourceRoot.path,
            work: shared.appending(path: "work/\(Self.digest(Data(sourceRoot.path.utf8)).prefix(16))").path,
            prefix: shared.appending(path: "host/\(valgrindBuild)").path
        )
        return try await measure(
            on: HostMachine(),
            layout: layout,
            processors: ProcessInfo.processInfo.activeProcessorCount,
            memoryGiB: Int(ProcessInfo.processInfo.physicalMemory >> 30),
            package: package,
            sourceRoot: sourceRoot,
            files: files,
            valgrindSource: valgrindSource,
            valgrindBuild: valgrindBuild,
            run: run,
            dumpsRoot: dumpsRoot
        )
        #endif
    }

    /// Where the recorder's directories are, as the machine that measures sees them.
    private struct Layout {
        /// The cache's `guest` directory: guest files, downloads, build products and dumps.
        let shared: String
        /// The checkout, read only.
        let source: String
        /// Where the checkout is staged and built.
        let work: String
        /// Where Valgrind and the shim are installed.
        let prefix: String
    }

    private func measure<Runner: Machine>(
        on machine: Runner,
        layout: Layout,
        processors: Int,
        memoryGiB: Int,
        package: URL,
        sourceRoot: URL,
        files: URL,
        valgrindSource: URL,
        valgrindBuild: String,
        run: String,
        dumpsRoot: URL
    ) async throws -> BenchmarkBaseline {
        let relativePackage = String(package.path.dropFirst(sourceRoot.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // The checkout keeps its directory name when staged, because SwiftPM names a path
        // dependency after its directory: `.package(path: "..")` must still be the same package.
        let stagedRoot = "\(layout.work)/\(sourceRoot.lastPathComponent)"
        let stagedPackage = relativePackage.isEmpty ? stagedRoot : "\(stagedRoot)/\(relativePackage)"
        let machineFiles = "\(layout.shared)/\(files.lastPathComponent)"
        // The archive holds an installation under one prefix, so each prefix has its own.
        let valgrindArchive = "\(layout.shared)/\(valgrindBuild)-\(Self.digest(Data(layout.prefix.utf8)).prefix(8)).tar"
        let scratch = "\(layout.shared)/scratch/\(Self.digest(Data(sourceRoot.path.utf8)).prefix(16))"
        let machineDumpsRoot = "\(layout.shared)/dumps/\(run)"
        let network = machine.networkEnvironment

        try await machine.check(
            ["/bin/bash", "\(machineFiles)/provision.sh", "\(layout.shared)/downloads/\(valgrindSource.lastPathComponent)", valgrindArchive, machineFiles, layout.prefix],
            environment: network
        )
        try await machine.check(["/bin/bash", "\(machineFiles)/stage.sh", layout.source, stagedRoot, scratch])

        let manifest = try await machine.output(["swift", "package", "dump-package", "--package-path", stagedPackage])
        let available = try Self.benchmarkTargets(inManifest: manifest)
        let selected = targets.isEmpty ? available : available.filter(targets.contains)
        guard !selected.isEmpty else { throw NoBenchmarkTargets(available: available) }

        let build = ["swift", "build", "-c", "release", "--package-path", stagedPackage, "--scratch-path", scratch]
        if selected == available {
            FileHandle.standardError.write(Data("Building \(selected.joined(separator: ", "))\n".utf8))
            try await machine.check(build, environment: network)
        } else {
            for target in selected {
                FileHandle.standardError.write(Data("Building \(target)\n".utf8))
                try await machine.check(build + ["--product", target], environment: network)
            }
        }
        let binPath = String(decoding: try await machine.output(build + ["--show-bin-path"]), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let kernelVersion = String(decoding: try await machine.output(["uname", "-r"]), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let architecture = String(decoding: try await machine.output(["uname", "-m"]), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let filters = try self.filters.map { try Regex($0) }
        let skips = try self.skips.map { try Regex($0) }
        @Sendable func process(_ target: String, dumps: String) -> BenchmarkProcess<Runner> {
            BenchmarkProcess(
                target: target,
                executable: "\(binPath)/\(target)",
                machine: machine,
                script: "\(machineFiles)/run-benchmarks.sh",
                prefix: layout.prefix,
                iterations: iterations,
                dumps: dumpsRoot.appending(path: dumps),
                machineDumps: "\(machineDumpsRoot)/\(dumps)"
            )
        }

        // Each target's benchmarks are listed once, then each benchmark is measured in a process of
        // its own, so its counts never depend on which benchmarks ran before it or were filtered out.
        let listed = try await Self.concurrently(selected, limit: jobs) { target in
            try await process(target, dumps: "\(target)/list").list()
        }.map { benchmarks in
            benchmarks.filter { benchmark in
                (filters.isEmpty || filters.contains { benchmark.name.firstMatch(of: $0) != nil })
                    && !skips.contains { benchmark.name.firstMatch(of: $0) != nil }
            }
        }
        let work = zip(selected, listed).flatMap { target, benchmarks in
            benchmarks.enumerated().map { index, benchmark in (target: target, index: index, benchmark: benchmark) }
        }
        let measured = try await Self.concurrently(work, limit: jobs) { unit in
            let simulated = try await process(unit.target, dumps: "\(unit.target)/\(unit.index)").measure(unit.benchmark)
            let counted = Self.countedMetrics(of: unit.benchmark)
                .filter { metric in !simulated.contains { $0.metric == metric } }
            guard !counted.isEmpty else { return simulated }
            var native = process(unit.target, dumps: "\(unit.target)/\(unit.index)-native")
            native.native = true
            let countedResults = try await native.count(unit.benchmark, metrics: counted)
            let values = countedResults.map { "\($0.metric.name) \($0.statistics.valueAtPercentile(50))" }
            FileHandle.standardOutput.write(Data("\(unit.target): \(unit.benchmark.name) (counted, p50) — \(values.joined(separator: ", "))\n".utf8))
            return simulated + countedResults
        }
        var results: [BenchmarkIdentifier: [BenchmarkResult]] = [:]
        for (unit, benchmarkResults) in zip(work, measured) {
            results[BenchmarkIdentifier(target: unit.target, name: unit.benchmark.name)] = benchmarkResults
        }

        let baseline = BenchmarkBaseline(
            baselineName: baselineName,
            machine: BenchmarkMachine(
                hostname: "benchmark-harness",
                processors: processors,
                processorType: "\(architecture) (Callgrind 3.28.0 simulation)",
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
        // Kept when measuring fails, for the Valgrind log an error points at.
        try? FileManager.default.removeItem(at: dumpsRoot)
        return baseline
    }

    /// The metrics `benchmark` is configured with that ordo-one/benchmark counts itself and that
    /// don't depend on time: allocation, free and leak counts, Swift object and reference counts,
    /// and every custom metric. They are measured without Valgrind and kept beside the simulated
    /// metrics.
    package static func countedMetrics(of benchmark: Benchmark) -> [BenchmarkMetric] {
        benchmark.metrics.filter { metric in
            switch metric {
            case .mallocCountSmall, .mallocCountLarge, .mallocCountTotal, .freeCountTotal, .mallocBytesCount,
                 .mallocFreeDelta, .memoryLeaked, .memoryLeakedBytes, .objectAllocCount, .retainCount,
                 .releaseCount, .retainReleaseDelta, .custom:
                true
            default:
                false
            }
        }
    }

    /// The results of `body` on each element, in order, running at most `limit` at once.
    private static func concurrently<Element: Sendable, Result: Sendable>(
        _ elements: [Element],
        limit: Int,
        _ body: @escaping @Sendable (Element) async throws -> Result
    ) async throws -> [Result] {
        try await withThrowingTaskGroup(of: (Int, Result).self) { group in
            var next = 0
            func startNext() {
                guard next < elements.count else { return }
                let index = next
                let element = elements[index]
                next += 1
                group.addTask { (index, try await body(element)) }
            }
            for _ in 0 ..< max(1, limit) { startNext() }
            var results = [Result?](repeating: nil, count: elements.count)
            while let (index, result) = try await group.next() {
                results[index] = result
                startNext()
            }
            return results.map { $0! }
        }
    }

    /// Reads a process's dumps in the order Callgrind wrote them, split into measured iterations and
    /// calibration windows, and deletes them.
    static func readDumps(in directory: URL) throws -> (iterations: [CallgrindDump], overhead: [CallgrindDump]) {
        let numbered = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .compactMap { name -> (Int, String)? in
                guard name.hasPrefix("callgrind.out."), let number = Int(name.dropFirst("callgrind.out.".count)) else { return nil }
                return (number, name)
            }
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
        return (iterations, overhead)
    }

    static func report(_ identifier: BenchmarkIdentifier, iterations: [CallgrindDump], overhead: [CallgrindDump], elapsed: Duration, results: [BenchmarkResult]) {
        let values = results.map { "\($0.metric.name) \($0.statistics.valueAtPercentile(50))" }
        let overheadInstructions = overhead.map { SimulatedMetric.instructions.value(in: $0) }.sorted()
        let windowCost = overheadInstructions.isEmpty ? 0 : overheadInstructions[(overheadInstructions.count - 1) / 2]
        // Unbuffered, so progress shows while a long run continues.
        FileHandle.standardOutput.write(Data(("\(identifier.target): \(identifier.name) (\(iterations.count) iterations in \(elapsed.formatted(.units(allowed: [.minutes, .seconds], width: .narrow))), p50, less \(windowCost) instructions of measuring) — \(values.joined(separator: ", "))" + "\n").utf8))
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

    #if os(macOS)
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
    #endif

    /// Copies the scripts and sources the guest runs onto the shared volume, into a directory
    /// named by their digest, and returns it.
    ///
    /// A run never changes files another run's guest may be reading: different contents get a
    /// different directory, and the same contents are installed once, by an atomic rename.
    private static func installGuestFiles(in shared: URL) throws -> URL {
        guard let resources = Bundle.module.url(forResource: "Guest", withExtension: nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: resources.path).sorted()
        var contents = Data()
        for name in names {
            contents += Data(name.utf8) + [0] + (try Data(contentsOf: resources.appending(path: name))) + [0]
        }
        let directory = shared.appending(path: "files-\(digest(contents).prefix(16))")
        guard !FileManager.default.fileExists(atPath: directory.path) else { return directory }
        let staging = shared.appending(path: "files-staging-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: resources, to: staging)
        do {
            try FileManager.default.moveItem(at: staging, to: directory)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            guard FileManager.default.fileExists(atPath: directory.path) else { throw error }
        }
        return directory
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
        default: String(describing: self)
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
