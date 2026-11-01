import Foundation

/// A Linux machine the harness runs commands on: a ``GuestMachine`` booted on macOS, or the
/// ``HostMachine`` it runs on under Linux.
public protocol Machine: Sendable {
    /// `NAME=value` pairs a command that reaches the network runs with.
    var networkEnvironment: [String] { get }

    /// Runs a command to completion.
    ///
    /// - Parameters:
    ///   - arguments: The program, found on `PATH`, and its arguments.
    ///   - environment: `NAME=value` pairs added to the machine's environment.
    ///   - input: The command's standard input, or `nil` for none. The input ends when the
    ///     sequence finishes.
    ///   - output: Where the command's standard output goes, or `nil` for the harness's standard
    ///     error. The continuation is finished before `run` returns.
    /// - Returns: The command's exit code.
    func run(
        _ arguments: [String],
        environment: [String],
        input: AsyncStream<Data>?,
        output: AsyncStream<Data>.Continuation?
    ) async throws -> Int32
}

extension Machine {
    /// Runs a command, with no input, writing its output to the harness's standard error.
    ///
    /// - Returns: The command's exit code.
    @discardableResult
    public func run(_ arguments: [String], environment: [String] = []) async throws -> Int32 {
        try await run(arguments, environment: environment, input: nil, output: nil)
    }

    /// Runs a command and returns its standard output.
    ///
    /// - Throws: ``MachineCommandFailed`` when the command exits with a non-zero code.
    public func output(_ arguments: [String], environment: [String] = []) async throws -> Data {
        let (chunks, continuation) = AsyncStream.makeStream(of: Data.self)
        let code = try await run(arguments, environment: environment, input: nil, output: continuation)
        guard code == 0 else { throw MachineCommandFailed(arguments: arguments, exitCode: code) }
        var data = Data()
        for await chunk in chunks { data += chunk }
        return data
    }

    /// Runs a command, throwing when it fails.
    ///
    /// - Throws: ``MachineCommandFailed`` when the command exits with a non-zero code.
    public func check(_ arguments: [String], environment: [String] = []) async throws {
        let code = try await run(arguments, environment: environment, input: nil, output: nil)
        guard code == 0 else { throw MachineCommandFailed(arguments: arguments, exitCode: code) }
    }
}

/// The error thrown when a command exits with a non-zero code.
public struct MachineCommandFailed: Error, CustomStringConvertible, Sendable {
    /// The command.
    public let arguments: [String]
    /// Its exit code.
    public let exitCode: Int32

    public var description: String {
        "\(arguments.joined(separator: " ")) exited with code \(exitCode)"
    }
}
