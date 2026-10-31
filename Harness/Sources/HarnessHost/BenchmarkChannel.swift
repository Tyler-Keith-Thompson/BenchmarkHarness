import BenchmarkCommands
import Foundation

/// The protocol stream of a benchmark executable running in the guest: requests go to its standard
/// input, replies come from its standard output.
struct BenchmarkChannel {
    private let input: AsyncStream<Data>.Continuation
    private var output: AsyncStream<Data>.AsyncIterator
    private var decoder = BenchmarkCommandDecoder()

    /// A channel writing to `input` and reading from `output`.
    init(input: AsyncStream<Data>.Continuation, output: AsyncStream<Data>) {
        self.input = input
        self.output = output.makeAsyncIterator()
    }

    /// Sends `request`.
    func send(_ request: BenchmarkCommandRequest) {
        input.yield(request.frame)
    }

    /// Closes the executable's input.
    func finish() {
        input.finish()
    }

    /// The next reply.
    ///
    /// - Throws: ``BenchmarkExecutableExited`` when the output ends first, or
    ///   ``MalformedBenchmarkCommand`` for output that is not a reply.
    mutating func receive() async throws -> BenchmarkCommandReply {
        while true {
            if let reply = try decoder.next() {
                return reply
            }
            guard let chunk = await output.next() else {
                throw BenchmarkExecutableExited()
            }
            decoder.append(chunk)
        }
    }
}

/// The error thrown when a benchmark executable's output ends in the middle of the protocol.
public struct BenchmarkExecutableExited: Error, CustomStringConvertible, Sendable {
    public var description: String {
        "The benchmark executable exited before replying; see valgrind.log in its dump directory"
    }
}
