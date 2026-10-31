/// The event totals of one Callgrind profile dump.
///
/// Callgrind writes a dump file at exit and on each `CALLGRIND_DUMP_STATS` client request. Its
/// `events:` line names the events counted, in column order, and its `totals:` line (`summary:` in
/// older files) holds their totals. A totals line may omit trailing zeros, so every event the
/// dump names has a total, zero when omitted. A `desc: Trigger:` line says what wrote the dump.
///
/// ```swift
/// let dump = CallgrindDump(text: """
///     events: Ir Dr Dw
///     totals: 1200 300
///     """)
/// dump[.instructionCacheReads]  // 1200
/// dump[.dataCacheWrites]        // 0
/// ```
@frozen
public struct CallgrindDump: Hashable, Sendable {
    /// The events the dump counts, in the order of its `events:` line.
    public let events: [CallgrindEvent]
    /// The total of each event in ``events``.
    public let totals: [CallgrindEvent: Int]
    /// What wrote the dump, such as `Client Request: iteration 3` for a
    /// `CALLGRIND_DUMP_STATS_AT("iteration 3")` request, or `nil` when the dump does not say.
    public let trigger: String?

    /// The dump parsed from the text of a Callgrind output file.
    ///
    /// - Parameter text: The file's contents. Traps when it has no `events:` line, no `totals:`
    ///   or `summary:` line, more totals than events, or a total that is not a non-negative
    ///   integer; use ``init(checkedText:)`` to throw instead.
    /// - Complexity: O(*n*), where *n* is the length of `text`.
    public init(text: some StringProtocol) {
        do {
            try self.init(checkedText: text)
        } catch {
            preconditionFailure("Malformed Callgrind dump")
        }
    }

    /// The dump parsed from the text of a Callgrind output file.
    ///
    /// - Parameter text: The file's contents.
    /// - Throws: ``MalformedCallgrindDump`` when the text has no `events:` line, no `totals:` or
    ///   `summary:` line, more totals than events, or a total that is not a non-negative integer.
    /// - Complexity: O(*n*), where *n* is the length of `text`.
    public init(checkedText text: some StringProtocol) throws(MalformedCallgrindDump) {
        var events: [CallgrindEvent]?
        var totals: [Substring]?
        var summary: [Substring]?
        var trigger: String?
        for line in String(text).split(whereSeparator: \.isNewline) {
            if line.hasPrefix("desc: Trigger:") {
                trigger = String(line.dropFirst("desc: Trigger:".count).drop(while: \.isWhitespace))
            } else if let fields = Self.fields(of: line, key: "events:") {
                events = fields.map { CallgrindEvent(rawValue: String($0)) }
            } else if let fields = Self.fields(of: line, key: "totals:") {
                totals = fields
            } else if let fields = Self.fields(of: line, key: "summary:") {
                summary = fields
            }
        }
        guard let events, let values = totals ?? summary, values.count <= events.count else {
            throw MalformedCallgrindDump()
        }
        var result: [CallgrindEvent: Int] = [:]
        for (index, event) in events.enumerated() {
            if index < values.count {
                guard let value = Int(values[index]), value >= 0 else { throw MalformedCallgrindDump() }
                result[event] = value
            } else {
                result[event] = 0
            }
        }
        self.events = events
        self.totals = result
        self.trigger = trigger
    }

    /// The total of `event`.
    ///
    /// - Parameter event: An event in ``events``. Traps for an event the dump does not count.
    /// - Complexity: O(1).
    public subscript(event: CallgrindEvent) -> Int {
        guard let total = totals[event] else {
            preconditionFailure("The dump does not count \(event.rawValue)")
        }
        return total
    }

    private static func fields(of line: Substring, key: String) -> [Substring]? {
        guard line.hasPrefix(key) else { return nil }
        return line.dropFirst(key.count).split(whereSeparator: \.isWhitespace)
    }
}

/// The error ``CallgrindDump/init(checkedText:)`` throws for text that is not a Callgrind dump.
@frozen
public struct MalformedCallgrindDump: Error, Hashable, Sendable {
    @inlinable
    public init() {}
}
