// Each test is self-contained: it builds its own values and states its own expectations, so it
// can be copied into another file and still run. Nothing here is shared but the imports.

import Foundation
import HarnessHost
import Synchronization
import Testing

@Suite("runUntilInterrupted", .serialized)
struct InterruptionTests {
    @Test("runUntilInterrupted returns what its body returns")
    func returnsResult() async throws {
        let expected = 42
        let result = try await runUntilInterrupted { expected }
        #expect(result == expected)
    }

    @Test("A SIGHUP cancels the body, waits for it to stop and throws Interrupted naming the signal")
    func signal() async throws {
        let cancelled = Mutex(false)
        @Sendable func body() async throws -> Int {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                cancelled.withLock { $0 = true }
                throw error
            }
            return 0
        }
        let raiser = Task {
            try await Task.sleep(for: .milliseconds(300))
            kill(getpid(), SIGHUP)
        }
        let error = await #expect(throws: Interrupted.self) {
            try await runUntilInterrupted { try await body() }
        }
        _ = try? await raiser.value
        let expectedReason = "received SIGHUP"
        #expect(error?.reason == expectedReason)
        #expect(cancelled.withLock { $0 })
    }
}
