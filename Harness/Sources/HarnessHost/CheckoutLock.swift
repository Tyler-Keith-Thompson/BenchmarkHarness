import Foundation

/// An exclusive advisory lock on a file (`flock(2)`), held by one run at a time.
///
/// The recorder holds one per checkout from staging to writing the baseline, so two runs on the
/// same checkout never share its build products mid-run; runs on different checkouts don't wait.
/// The lock is released when the value is released or the process ends. While held, the file
/// holds the holder's process identifier, so a waiting run can say whom it waits for.
package final class CheckoutLock: Sendable {
    private let descriptor: Int32

    /// Acquires the lock on `file`, creating it if needed, and waits while another holder has it.
    ///
    /// - Parameters:
    ///   - file: The lock file.
    ///   - waiting: Called once if the lock is held elsewhere, before waiting, with the holder's
    ///     process identifier when the file names one.
    /// - Throws: `CocoaError` when the file can't be opened, and `CancellationError` when the task
    ///   is cancelled while waiting.
    package init(file: URL, waiting: (_ holder: Int32?) -> Void = { _ in }) async throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(file.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
        }
        var told = false
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else {
                close(descriptor)
                throw CocoaError(.fileLocking, userInfo: [NSFilePathErrorKey: file.path])
            }
            if !told {
                let contents = try? String(contentsOf: file, encoding: .utf8)
                waiting(contents.flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
                told = true
            }
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                close(descriptor)
                throw error
            }
        }
        let holder = Array("\(getpid())\n".utf8)
        _ = ftruncate(descriptor, 0)
        _ = holder.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }
}
