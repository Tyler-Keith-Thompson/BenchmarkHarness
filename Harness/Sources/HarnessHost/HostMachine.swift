import Foundation

/// The Linux machine the harness itself runs on, where commands run as its own child processes.
///
/// Commands inherit the harness's environment and reach the network directly.
public struct HostMachine: Machine {
    /// The host.
    public init() {
        // A command can exit before reading all its input; writing to it then fails with EPIPE
        // rather than ending the harness.
        signal(SIGPIPE, SIG_IGN)
    }

    public var networkEnvironment: [String] { [] }

    public func run(
        _ arguments: [String],
        environment: [String],
        input: AsyncStream<Data>?,
        output: AsyncStream<Data>.Continuation?
    ) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        var variables = ProcessInfo.processInfo.environment
        for pair in environment {
            guard let separator = pair.firstIndex(of: "=") else { continue }
            variables[String(pair[..<separator])] = String(pair[pair.index(after: separator)...])
        }
        process.environment = variables
        process.standardError = FileHandle.standardError

        // Ends once the command's output reaches end of file, which can come after it terminates.
        // A thread of its own reads until then: on Linux a readability handler isn't told of end
        // of file once data has arrived.
        let (outputEnded, outputEndedContinuation) = AsyncStream.makeStream(of: Never.self)
        let outputPipe = output.map { _ in Pipe() }
        process.standardOutput = outputPipe ?? FileHandle.standardError

        let inputPipe = input.map { _ in Pipe() }
        process.standardInput = inputPipe ?? FileHandle.nullDevice

        let (terminated, terminatedContinuation) = AsyncStream.makeStream(of: Int32.self)
        process.terminationHandler = { process in
            let status = process.terminationStatus
            terminatedContinuation.yield(process.terminationReason == .uncaughtSignal ? 128 + status : status)
            terminatedContinuation.finish()
        }
        try process.run()
        if let output, let outputPipe {
            let handle = outputPipe.fileHandleForReading
            Thread {
                while case let data = handle.availableData, !data.isEmpty {
                    output.yield(data)
                }
                output.finish()
                outputEndedContinuation.finish()
            }.start()
        } else {
            outputEndedContinuation.finish()
        }

        let writer: Task<Void, Never>? = if let input, let inputPipe {
            Task {
                let handle = inputPipe.fileHandleForWriting
                for await chunk in input {
                    guard (try? handle.write(contentsOf: chunk)) != nil else { break }
                }
                try? handle.close()
            }
        } else {
            nil
        }
        var code: Int32 = -1
        for await status in terminated { code = status }
        writer?.cancel()
        for await _ in outputEnded {}
        return code
    }
}
