import Foundation

/// The harness's cache directory, and the rules that keep it from growing without bound.
///
/// Each checkout a run measures keeps its build products between runs, so builds stay
/// incremental: on macOS the disk image `guest/builds/<checkout>.ext4`, on Linux the directories
/// `guest/builds/<checkout>` and `guest/work/<checkout>`, where `<checkout>` is the digest of the
/// checkout's path. Beside them, `guest/builds/<checkout>.json` records that path, and its
/// modification time is when a run last used them. ``evict(limitInBytes:)`` deletes what no run
/// will use again and the least recently used builds over a limit, never touching a checkout
/// whose ``CheckoutLock`` another run holds.
package struct HarnessCache: Sendable {
    /// The cache directory.
    package let path: URL

    /// The cache at `path`.
    package init(path: URL) {
        self.path = path
    }

    /// The default limit on the checkouts' builds: 50 GiB.
    package static let defaultLimitInBytes: UInt64 = 50 << 30

    /// The lock file a run holds while it uses `checkout`'s builds.
    package func lockFile(checkout: String) -> URL {
        guest.appending(path: "locks/\(checkout).lock")
    }

    /// Records that a run is using `checkout`'s builds, for the checkout at `source`.
    ///
    /// Call it while holding the checkout's lock.
    ///
    /// - Throws: An error writing the record.
    package func recordUse(checkout: String, source: URL) throws {
        let builds = guest.appending(path: "builds")
        try FileManager.default.createDirectory(at: builds, withIntermediateDirectories: true)
        try JSONEncoder().encode(Record(path: source.path)).write(to: builds.appending(path: "\(checkout).json"), options: .atomic)
    }

    /// Deletes what the cache holds that no run will use again, then the least recently used
    /// checkouts' builds until the builds take at most `limitInBytes`.
    ///
    /// It deletes:
    /// - the builds of each checkout whose path no longer exists, or that has no record of its
    ///   path;
    /// - the scratch directories of `guest/scratch`, where builds were kept before the disk
    ///   images;
    /// - the container file systems in `store/containers`, and the dumps in `guest/dumps` older
    ///   than a day, of runs whose process has ended;
    /// - then, while the remaining builds take more than `limitInBytes`, the least recently used
    ///   checkout's.
    ///
    /// A checkout whose lock another holder has (a run using it, this process's own included) is
    /// skipped, so its builds count toward the limit but stay.
    ///
    /// - Parameter limitInBytes: The most the checkouts' builds may take on disk, counting the
    ///   blocks a sparse image has allocated rather than its size.
    /// - Returns: The checkouts whose builds were deleted, sorted.
    /// - Complexity: O(*n* log *n*) in the number of checkouts, plus the files their builds hold.
    @discardableResult
    package func evict(limitInBytes: UInt64) -> [String] {
        removeEndedRuns()
        var evicted: [String] = []
        for checkout in entries(in: guest.appending(path: "scratch")) where !checkout.hasPrefix(".") {
            withLock(checkout) { try? FileManager.default.removeItem(at: guest.appending(path: "scratch/\(checkout)")) }
        }

        var kept: [Checkout] = []
        for checkout in checkouts() {
            if checkout.isStale, withLock(checkout.name, { delete(checkout) }) {
                evicted.append(checkout.name)
            } else {
                kept.append(checkout)
            }
        }
        var total = kept.reduce(0) { $0 + $1.allocatedBytes }
        for checkout in kept.sorted(by: { ($0.lastUsed, $0.name) < ($1.lastUsed, $1.name) }) where total > limitInBytes {
            if withLock(checkout.name, { delete(checkout) }) {
                evicted.append(checkout.name)
                total -= checkout.allocatedBytes
            }
        }
        return evicted.sorted()
    }
}

extension HarnessCache {
    /// What `guest/builds/<checkout>.json` holds.
    fileprivate struct Record: Codable {
        let path: String
    }

    /// One checkout's builds.
    fileprivate struct Checkout {
        let name: String
        let files: [URL]
        let record: URL
        let source: String?
        let lastUsed: Date
        let allocatedBytes: UInt64

        /// No run will use them again: the checkout is gone, or nothing says where it was.
        var isStale: Bool {
            source.map { !FileManager.default.fileExists(atPath: $0) } ?? true
        }
    }

    fileprivate var guest: URL { path.appending(path: "guest") }

    /// Every checkout with builds or a record, by the digest its files are named for.
    fileprivate func checkouts() -> [Checkout] {
        let builds = guest.appending(path: "builds")
        let work = guest.appending(path: "work")
        let names = Set(
            entries(in: builds).filter { !$0.hasPrefix(".") }.map { name in
                name.hasSuffix(".ext4") || name.hasSuffix(".json") ? String(name.dropLast(5)) : name
            } + entries(in: work).filter { !$0.hasPrefix(".") }
        )
        return names.sorted().map { name in
            let record = builds.appending(path: "\(name).json")
            let files = [builds.appending(path: "\(name).ext4"), builds.appending(path: name), work.appending(path: name)]
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            let source = (try? Data(contentsOf: record)).flatMap { try? JSONDecoder().decode(Record.self, from: $0) }?.path
            let lastUsed = ([record] + files).compactMap(\.modificationDate).max() ?? .distantPast
            return Checkout(
                name: name,
                files: files,
                record: record,
                source: source,
                lastUsed: lastUsed,
                allocatedBytes: files.reduce(0) { $0 + $1.allocatedBytes }
            )
        }
    }

    fileprivate func delete(_ checkout: Checkout) {
        for file in checkout.files {
            try? FileManager.default.removeItem(at: file)
        }
        try? FileManager.default.removeItem(at: checkout.record)
    }

    /// Runs `body` holding `checkout`'s lock, unless another holder has it.
    ///
    /// - Returns: Whether `body` ran.
    @discardableResult
    fileprivate func withLock(_ checkout: String, _ body: () -> Void) -> Bool {
        // The lock file stays: deleting it would let a run waiting on the old file and one
        // opening a new file both hold "the" lock.
        guard let lock = try? CheckoutLock(attempting: lockFile(checkout: checkout)) else { return false }
        body()
        withExtendedLifetime(lock) {}
        return true
    }

    /// Deletes the container file systems and old dumps of runs whose process has ended.
    ///
    /// A run killed before it can shut its guest down (SIGKILL, a crash) leaves its container's
    /// 4 GiB root file system behind; containers and dumps are named for the run's process.
    fileprivate func removeEndedRuns() {
        let containers = path.appending(path: "store/containers")
        for name in entries(in: containers) {
            guard name.hasPrefix("benchmark-harness-"),
                  let process = Int32(name.dropFirst("benchmark-harness-".count)),
                  !process.isRunning
            else { continue }
            try? FileManager.default.removeItem(at: containers.appending(path: name))
        }
        // A failed run's dumps hold the Valgrind log its error points at, so they stay a day.
        let dumps = guest.appending(path: "dumps")
        let dayAgo = Date(timeIntervalSinceNow: -86_400)
        for name in entries(in: dumps) {
            let directory = dumps.appending(path: name)
            guard let process = name.split(separator: "-").first.flatMap({ Int32($0) }),
                  !process.isRunning,
                  (directory.modificationDate ?? .distantPast) < dayAgo
            else { continue }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    fileprivate func entries(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }
}

extension URL {
    fileprivate var modificationDate: Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// The bytes the file, or everything under the directory, takes on disk: the blocks allocated,
    /// so a sparse image counts only what has been written to it.
    fileprivate var allocatedBytes: UInt64 {
        var status = stat()
        guard lstat(path, &status) == 0 else { return 0 }
        var total = UInt64(status.st_blocks) * 512
        guard (status.st_mode & S_IFMT) == S_IFDIR,
              let enumerator = FileManager.default.enumerator(atPath: path)
        else { return total }
        for case let relative as String in enumerator {
            var child = stat()
            if lstat("\(path)/\(relative)", &child) == 0 {
                total += UInt64(child.st_blocks) * 512
            }
        }
        return total
    }
}

extension Int32 {
    /// Whether a process with this identifier is running.
    fileprivate var isRunning: Bool {
        kill(self, 0) == 0 || errno == EPERM
    }
}
