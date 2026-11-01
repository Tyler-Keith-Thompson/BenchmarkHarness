// Each test is self-contained: it builds its own values and states its own expectations, so it
// can be copied into another file and still run. Nothing here is shared but the imports.

import Foundation
import HarnessHost
import Synchronization
import Testing

@Suite("CheckoutLock")
struct CheckoutLockTests {
    @Test("A second lock on the same file waits, telling its caller once, until the first is released")
    func waitsForHolder() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "checkout-lock-\(UUID().uuidString)/a.lock")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var first: CheckoutLock? = try await CheckoutLock(file: file)
        let waits = Mutex(0)
        let acquired = Mutex(false)
        let second = Task {
            let lock = try await CheckoutLock(file: file) { _ in waits.withLock { $0 += 1 } }
            acquired.withLock { $0 = true }
            withExtendedLifetime(lock) {}
        }
        try await Task.sleep(for: .milliseconds(600))
        #expect(acquired.withLock { $0 } == false)
        withExtendedLifetime(first) {}
        first = nil
        try await second.value
        let expectedWaits = 1
        #expect(acquired.withLock { $0 })
        #expect(waits.withLock { $0 } == expectedWaits)
    }

    @Test("A waiting lock is told the holder's process identifier")
    func namesHolder() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "checkout-lock-\(UUID().uuidString)/a.lock")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let holder = try await CheckoutLock(file: file)
        let reported = Mutex<Int32?>(nil)
        let waiter = Task {
            _ = try await CheckoutLock(file: file) { process in reported.withLock { $0 = process } }
        }
        try await Task.sleep(for: .milliseconds(300))
        waiter.cancel()
        _ = try? await waiter.value
        withExtendedLifetime(holder) {}
        let expected: Int32? = getpid()
        #expect(reported.withLock { $0 } == expected)
    }

    @Test("Locks on different files don't wait for each other")
    func differentFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "checkout-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let waits = Mutex(0)
        let first = try await CheckoutLock(file: directory.appending(path: "a.lock")) { _ in waits.withLock { $0 += 1 } }
        let second = try await CheckoutLock(file: directory.appending(path: "b.lock")) { _ in waits.withLock { $0 += 1 } }
        withExtendedLifetime((first, second)) {}
        #expect(waits.withLock { $0 } == 0)
    }

    @Test("A waiting lock stops waiting when its task is cancelled")
    func cancellation() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "checkout-lock-\(UUID().uuidString)/a.lock")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let holder = try await CheckoutLock(file: file)
        let waiter = Task { _ = try await CheckoutLock(file: file) }
        try await Task.sleep(for: .milliseconds(300))
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        withExtendedLifetime(holder) {}
    }
}
