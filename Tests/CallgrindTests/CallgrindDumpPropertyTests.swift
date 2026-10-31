// Property tests against a naive reference. Each test is self-contained; see
// CallgrindDumpTests.swift.

import BenchmarkHarnessTestSupport
import Callgrind
import PropertyBased
import Testing

@Suite("CallgrindDump: properties")
struct CallgrindDumpPropertyTests {
    @Test("A rendered dump parses back to its events and totals", .tags(.randomized))
    func roundTrip() async {
        let totals = Gen.int(in: 0 ... 1_000_000_000).array(of: 1 ... 13)
        let omitted = Gen.int(in: 0 ... 13)
        await propertyCheck(count: 300, input: totals, omitted) { totals, omitted in
            let names = ["Ir", "Dr", "Dw", "I1mr", "D1mr", "D1mw", "ILmr", "DLmr", "DLmw", "Bc", "Bcm", "Bi", "Bim"]
            let events = names.prefix(totals.count).map(CallgrindEvent.init(rawValue:))
            let written = totals.dropLast(min(omitted, totals.count))
            let text = "events: \(events.map(\.rawValue).joined(separator: " "))\n"
                + "totals: \(written.map(String.init).joined(separator: " "))\n"
            let dump = CallgrindDump(text: text)
            #expect(dump.events == Array(events))
            for (index, event) in events.enumerated() {
                let expected = index < written.count ? totals[index] : 0
                #expect(dump[event] == expected)
            }
        }
    }

    @Test("A seeded generator reproduces the same dumps", .tags(.randomized))
    func seededReproducibility() {
        var first = BenchmarkHarnessTestSupport.SeededRandomNumberGenerator(seed: 7)
        var second = BenchmarkHarnessTestSupport.SeededRandomNumberGenerator(seed: 7)
        func text(_ generator: inout BenchmarkHarnessTestSupport.SeededRandomNumberGenerator) -> String {
            let values = (0 ..< 4).map { _ in Int.random(in: 0 ... 1000, using: &generator) }
            return "events: Ir Dr Dw Bc\ntotals: \(values.map(String.init).joined(separator: " "))\n"
        }
        #expect(CallgrindDump(text: text(&first)) == CallgrindDump(text: text(&second)))
    }
}
