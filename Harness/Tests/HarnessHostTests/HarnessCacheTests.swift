// Each test is self-contained: it builds its own values and states its own expectations, so it
// can be copied into another file and still run. Nothing here is shared but the imports.

import Foundation
import HarnessHost
import Testing

@Suite("HarnessCache")
struct HarnessCacheTests {
    @Test("Eviction deletes the builds of checkouts that no longer exist or have no record, and keeps the rest")
    func staleCheckouts() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "harness-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = HarnessCache(path: root.appending(path: "cache"))
        let builds = root.appending(path: "cache/guest/builds")
        let work = root.appending(path: "cache/guest/work")
        let existing = root.appending(path: "existing")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: builds.appending(path: "dddd"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work.appending(path: "dddd"), withIntermediateDirectories: true)
        for name in ["aaaa", "bbbb", "cccc"] {
            try Data([1]).write(to: builds.appending(path: "\(name).ext4"))
        }
        try cache.recordUse(checkout: "aaaa", source: root.appending(path: "deleted"))
        try cache.recordUse(checkout: "bbbb", source: existing)
        try cache.recordUse(checkout: "dddd", source: root.appending(path: "deleted"))
        let limit = UInt64.max

        let actual = cache.evict(limitInBytes: limit)

        let expected = ["aaaa", "cccc", "dddd"]
        #expect(actual == expected)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: builds.path).sorted()
        let expectedRemaining = ["bbbb.ext4", "bbbb.json"]
        #expect(remaining == expectedRemaining)
        #expect(!FileManager.default.fileExists(atPath: work.appending(path: "dddd").path))
    }

    @Test("Over the limit, eviction deletes the least recently used checkouts' builds until they fit")
    func leastRecentlyUsed() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "harness-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = HarnessCache(path: root.appending(path: "cache"))
        let builds = root.appending(path: "cache/guest/builds")
        try FileManager.default.createDirectory(at: builds, withIntermediateDirectories: true)
        let mebibyte = Data(repeating: 7, count: 1 << 20)
        let now = Date()
        let ages: [(name: String, secondsAgo: TimeInterval)] = [("newest", 60), ("oldest", 3_600), ("middle", 600)]
        for (name, secondsAgo) in ages {
            let source = root.appending(path: "sources/\(name)")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try mebibyte.write(to: builds.appending(path: "\(name).ext4"))
            try cache.recordUse(checkout: name, source: source)
            let used = now.addingTimeInterval(-secondsAgo)
            for file in ["\(name).ext4", "\(name).json"] {
                try FileManager.default.setAttributes([.modificationDate: used], ofItemAtPath: builds.appending(path: file).path)
            }
        }
        let limit: UInt64 = (2 << 20) + (1 << 19)

        let actual = cache.evict(limitInBytes: limit)

        let expected = ["oldest"]
        #expect(actual == expected)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: builds.path).filter { $0.hasSuffix(".ext4") }.sorted()
        let expectedRemaining = ["middle.ext4", "newest.ext4"]
        #expect(remaining == expectedRemaining)
    }

    @Test("Under the limit, eviction keeps every existing checkout's builds")
    func underLimit() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "harness-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = HarnessCache(path: root.appending(path: "cache"))
        let builds = root.appending(path: "cache/guest/builds")
        try FileManager.default.createDirectory(at: builds, withIntermediateDirectories: true)
        let source = root.appending(path: "source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 1 << 20).write(to: builds.appending(path: "aaaa.ext4"))
        try cache.recordUse(checkout: "aaaa", source: source)
        let limit: UInt64 = 2 << 20

        let actual = cache.evict(limitInBytes: limit)

        #expect(actual.isEmpty)
        #expect(FileManager.default.fileExists(atPath: builds.appending(path: "aaaa.ext4").path))
    }

    @Test("Eviction never deletes the builds of a checkout whose lock is held, stale or least recently used")
    func lockedCheckouts() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "harness-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = HarnessCache(path: root.appending(path: "cache"))
        let builds = root.appending(path: "cache/guest/builds")
        try FileManager.default.createDirectory(at: builds, withIntermediateDirectories: true)
        let mebibyte = Data(repeating: 7, count: 1 << 20)
        try mebibyte.write(to: builds.appending(path: "stale.ext4"))
        let now = Date()
        for (name, secondsAgo) in [("oldest", 3_600.0), ("newer", 60.0)] {
            let source = root.appending(path: "sources/\(name)")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try mebibyte.write(to: builds.appending(path: "\(name).ext4"))
            try cache.recordUse(checkout: name, source: source)
            for file in ["\(name).ext4", "\(name).json"] {
                try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-secondsAgo)], ofItemAtPath: builds.appending(path: file).path)
            }
        }
        let staleLock = try await CheckoutLock(file: cache.lockFile(checkout: "stale"))
        let oldestLock = try await CheckoutLock(file: cache.lockFile(checkout: "oldest"))
        let limit: UInt64 = 1 << 20

        let actual = cache.evict(limitInBytes: limit)

        withExtendedLifetime((staleLock, oldestLock)) {}
        let expected = ["newer"]
        #expect(actual == expected)
        #expect(FileManager.default.fileExists(atPath: builds.appending(path: "stale.ext4").path))
        #expect(FileManager.default.fileExists(atPath: builds.appending(path: "oldest.ext4").path))
    }

    @Test("Eviction deletes old scratch directories, the containers of runs whose process has ended, and their dumps after a day")
    func leftovers() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "harness-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = HarnessCache(path: root.appending(path: "cache"))
        let ended = Process()
        ended.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try ended.run()
        ended.waitUntilExit()
        let containers = root.appending(path: "cache/store/containers")
        let endedContainer = containers.appending(path: "benchmark-harness-\(ended.processIdentifier)")
        let runningContainer = containers.appending(path: "benchmark-harness-\(getpid())")
        let scratch = root.appending(path: "cache/guest/scratch/aaaa")
        let oldDumps = root.appending(path: "cache/guest/dumps/\(ended.processIdentifier)-old")
        let recentDumps = root.appending(path: "cache/guest/dumps/\(ended.processIdentifier)-recent")
        for directory in [endedContainer, runningContainer, scratch, oldDumps, recentDumps] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -2 * 86_400)], ofItemAtPath: oldDumps.path)
        let limit = UInt64.max

        cache.evict(limitInBytes: limit)

        #expect(!FileManager.default.fileExists(atPath: endedContainer.path))
        #expect(FileManager.default.fileExists(atPath: runningContainer.path))
        #expect(!FileManager.default.fileExists(atPath: scratch.path))
        #expect(!FileManager.default.fileExists(atPath: oldDumps.path))
        #expect(FileManager.default.fileExists(atPath: recentDumps.path))
    }

    @Test("Eviction of an empty cache deletes nothing")
    func emptyCache() {
        let root = FileManager.default.temporaryDirectory.appending(path: "harness-cache-\(UUID().uuidString)")
        let cache = HarnessCache(path: root)
        let limit: UInt64 = 0

        let actual = cache.evict(limitInBytes: limit)

        #expect(actual.isEmpty)
    }
}
