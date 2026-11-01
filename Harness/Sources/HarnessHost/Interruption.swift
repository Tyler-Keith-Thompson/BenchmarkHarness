import Foundation
import Synchronization

/// The error thrown when ``runUntilInterrupted(_:)`` stops its work.
public struct Interrupted: Error, CustomStringConvertible, Sendable {
    /// Why the work stopped: the signal received, or the parent process exiting.
    public let reason: String

    public var description: String { "Stopped: \(reason)" }
}

/// Runs `body`, cancelling it when the process receives SIGINT, SIGTERM or SIGHUP, or when the
/// process that started this one exits.
///
/// Cancellation reaches the commands `body` runs on a ``Machine``, which end them, so a stopped
/// run leaves no benchmark process, virtual machine or checkout lock behind. A wrapper that is
/// killed without passing its signal on (`perl -e 'alarm N; exec @ARGV' just …` kills `just`) is
/// noticed by this process's parent changing. Both are checked every tenth of a second.
///
/// While `body` runs, the three signals no longer end the process directly; they are restored
/// to their default actions when it returns.
///
/// - Returns: What `body` returns.
/// - Throws: ``Interrupted`` once `body` has stopped after a signal or the parent's exit, and
///   whatever `body` throws otherwise.
public func runUntilInterrupted<Result: Sendable>(
    _ body: @escaping @Sendable () async throws -> Result
) async throws -> Result {
    let parent = getppid()
    let signals: [(number: Int32, name: String)] = [(SIGINT, "SIGINT"), (SIGTERM, "SIGTERM"), (SIGHUP, "SIGHUP")]
    receivedSignal.store(0, ordering: .relaxed)
    // A plain handler, not a dispatch source: on Linux a dispatch source blocks its signal only on
    // the thread that made it, so another thread can take the signal and drop it.
    for signal in signals {
        Foundation.signal(signal.number) { number in receivedSignal.store(number, ordering: .relaxed) }
    }
    defer {
        for signal in signals { Foundation.signal(signal.number, SIG_DFL) }
    }
    return try await withThrowingTaskGroup(of: Result?.self) { group in
        group.addTask { try await body() }
        group.addTask {
            while true {
                let number = receivedSignal.load(ordering: .relaxed)
                if let signal = signals.first(where: { $0.number == number }) {
                    throw Interrupted(reason: "received \(signal.name)")
                }
                if getppid() != parent {
                    throw Interrupted(reason: "the process that started benchmark-harness exited")
                }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        // The first task to finish decides: body's result, or an interruption, after which the
        // group cancels body and waits for it to clean up before the error leaves.
        while let finished = try await group.next() {
            if let result = finished {
                group.cancelAll()
                return result
            }
        }
        throw CancellationError()
    }
}

/// The last of the watched signals received, set by their handler; zero for none.
private let receivedSignal = Atomic<Int32>(0)
