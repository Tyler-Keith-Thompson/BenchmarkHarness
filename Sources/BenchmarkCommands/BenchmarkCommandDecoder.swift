import Foundation

/// Decodes the replies in a benchmark executable's output, however its bytes arrive.
///
/// Append bytes as they are read, then call ``next()`` until it returns `nil`: a frame split across
/// reads is held until the rest arrives.
///
/// ```swift
/// var decoder = BenchmarkCommandDecoder()
/// decoder.append(chunk)
/// while let reply = try decoder.next() {
///     handle(reply)
/// }
/// ```
@frozen
public struct BenchmarkCommandDecoder: Sendable {
    /// The largest frame accepted: 1 GiB.
    public static let maximumFrameLength = 1 << 30

    @usableFromInline
    var buffer = Data()

    /// A decoder with no bytes buffered.
    @inlinable
    public init() {}

    /// Buffers `bytes`, the next bytes of the executable's output.
    ///
    /// - Complexity: Amortized O(*n*), where *n* is the number of bytes.
    @inlinable
    public mutating func append(_ bytes: some Sequence<UInt8>) {
        buffer.append(contentsOf: bytes)
    }

    /// The bytes appended but not yet decoded.
    @inlinable
    public var bufferedByteCount: Int {
        buffer.count
    }

    /// The next complete reply, or `nil` when the buffered bytes do not yet hold one.
    ///
    /// - Throws: ``MalformedBenchmarkCommand`` when a frame's length is negative or larger than
    ///   ``maximumFrameLength``, or its JSON is not a reply. The decoder is then unusable.
    /// - Complexity: O(*n*), where *n* is the length of the frame.
    public mutating func next() throws(MalformedBenchmarkCommand) -> BenchmarkCommandReply? {
        guard buffer.count >= 8 else { return nil }
        let length = buffer.prefix(8).reversed().reduce(Int64(0)) { $0 << 8 | Int64($1) }
        guard length >= 0, length <= Self.maximumFrameLength else { throw MalformedBenchmarkCommand() }
        let end = 8 + Int(length)
        guard buffer.count >= end else { return nil }
        let json = Data(buffer[buffer.startIndex + 8 ..< buffer.startIndex + end])
        buffer = Data(buffer.dropFirst(end))
        return try BenchmarkCommandReply(json: json)
    }
}
