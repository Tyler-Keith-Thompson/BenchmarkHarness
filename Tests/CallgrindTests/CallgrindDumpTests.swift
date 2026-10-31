// Each test is self-contained: it builds its own values and states its own expectations, so it
// can be copied into another file and still run. Nothing here is shared but the imports.

import BenchmarkHarnessTestSupport
import Callgrind
import Testing

@Suite("CallgrindDump: hand-worked cases")
struct CallgrindDumpTests {
    @Test("A dump written by Callgrind 3.28 with cache and branch simulation parses", .tags(.fixture))
    func realDump() throws {
        let text = """
            # callgrind format
            version: 1
            creator: callgrind-3.28.0
            pid: 14
            cmd:  /build/release/SpikeBenchmarks --filter ^Sum1000$
            part: 1


            desc: I1 cache: 16384 B, 64 B, 4-way associative
            desc: D1 cache: 16384 B, 64 B, 4-way associative
            desc: LL cache: 262144 B, 64 B, 8-way associative

            desc: Timerange: Basic block 0 - 6267112
            desc: Trigger: Client Request: iteration 0

            positions: line
            events: Ir Dr Dw I1mr D1mr D1mw ILmr DLmr DLmw Bc Bcm Bi Bim
            summary: 3255 778 340 36 12 4 16 1 1 599 38 52 2


            ob=(1) /build/release/SpikeBenchmarks
            fl=(1) ???
            fn=(1) 0x0000000000123456
            0 3255 778 340 36 12 4 16 1 1 599 38 52 2

            totals: 3255 778 340 36 12 4 16 1 1 599 38 52 2
            """
        let dump = try CallgrindDump(checkedText: text)
        let expectedEvents: [CallgrindEvent] = [
            .instructionCacheReads, .dataCacheReads, .dataCacheWrites,
            .level1InstructionCacheReadMisses, .level1DataCacheReadMisses, .level1DataCacheWriteMisses,
            .lastLevelInstructionCacheReadMisses, .lastLevelDataCacheReadMisses, .lastLevelDataCacheWriteMisses,
            .conditionalBranches, .conditionalBranchMispredictions, .indirectBranches, .indirectBranchMispredictions,
        ]
        let expectedTrigger: String? = "Client Request: iteration 0"
        let instructions = 3255
        let indirectMispredictions = 2
        #expect(dump.events == expectedEvents)
        #expect(dump.trigger == expectedTrigger)
        #expect(dump[.instructionCacheReads] == instructions)
        #expect(dump[.indirectBranchMispredictions] == indirectMispredictions)
    }

    @Test("Totals omitted at the end of the line are zero")
    func omittedTrailingTotals() {
        let dump = CallgrindDump(text: "events: Ir Dr Dw\ntotals: 1200 300\n")
        let reads = 1200
        let dataReads = 300
        let writes = 0
        #expect(dump[.instructionCacheReads] == reads)
        #expect(dump[.dataCacheReads] == dataReads)
        #expect(dump[.dataCacheWrites] == writes)
    }

    @Test("A totals line with no values gives every event a total of zero")
    func emptyTotals() {
        let dump = CallgrindDump(text: "events: Ir Bcm\ntotals:\n")
        let expected: [CallgrindEvent: Int] = [.instructionCacheReads: 0, .conditionalBranchMispredictions: 0]
        #expect(dump.totals == expected)
    }

    @Test("The summary line stands in for a missing totals line, and totals win over it")
    func summaryFallback() {
        let summaryOnly = CallgrindDump(text: "events: Ir\nsummary: 7\n")
        let both = CallgrindDump(text: "events: Ir\nsummary: 7\ntotals: 9\n")
        let fromSummary = 7
        let fromTotals = 9
        #expect(summaryOnly[.instructionCacheReads] == fromSummary)
        #expect(both[.instructionCacheReads] == fromTotals)
    }

    @Test("A dump with one event parses, and an event the dump does not name is absent")
    func oneEvent() {
        let dump = CallgrindDump(text: "events: Ir\ntotals: 42\n")
        let expectedEvents: [CallgrindEvent] = [.instructionCacheReads]
        #expect(dump.events == expectedEvents)
        #expect(dump.totals[.dataCacheReads] == nil)
        #expect(dump.trigger == nil)
    }

    @Test("An event outside the simulated set keeps its abbreviation")
    func unknownEvent() {
        let dump = CallgrindDump(text: "events: Ir sysCount\ntotals: 10 3\n")
        let syscalls = 3
        #expect(dump[CallgrindEvent(rawValue: "sysCount")] == syscalls)
    }

    @Test("Lines end with LF or CRLF")
    func lineEndings() {
        let dump = CallgrindDump(text: "events: Ir Dr\r\ntotals: 5 6\r\n")
        let reads = 6
        #expect(dump[.dataCacheReads] == reads)
    }

    @Test("Equal text parses to equal dumps", .tags(.conformance))
    func equality() {
        let a = CallgrindDump(text: "events: Ir\ntotals: 1\n")
        let b = CallgrindDump(text: "events:  Ir\n\ntotals: 1\n")
        let c = CallgrindDump(text: "events: Ir\ntotals: 2\n")
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
        #expect(a != c)
    }

    @Test("The checked spelling throws MalformedCallgrindDump for text that is not a dump")
    func checkedMalformed() {
        let malformed = [
            "",
            "totals: 1 2\n",
            "events: Ir\n",
            "events: Ir\ntotals: 1 2\n",
            "events: Ir\ntotals: -1\n",
            "events: Ir\ntotals: many\n",
        ]
        for text in malformed {
            #expect(throws: MalformedCallgrindDump()) {
                try CallgrindDump(checkedText: text)
            }
        }
    }

    @Test("The checked spelling gives the same dump as the plain one")
    func checkedAgreesWithPlain() throws {
        let text = "events: Ir Bc\ndesc: Trigger: Program termination\ntotals: 4 2\n"
        let plain = CallgrindDump(text: text)
        let checked = try CallgrindDump(checkedText: text)
        #expect(plain == checked)
    }

    @Test("The plain spelling traps on text that is not a dump", .tags(.precondition))
    func plainMalformedTraps() async {
        await #expect(processExitsWith: .failure) {
            _ = CallgrindDump(text: "events: Ir\n")
        }
    }

    @Test("Reading an event the dump does not count traps", .tags(.precondition))
    func missingEventTraps() async {
        await #expect(processExitsWith: .failure) {
            let dump = CallgrindDump(text: "events: Ir\ntotals: 1\n")
            _ = dump[.dataCacheReads]
        }
    }
}
