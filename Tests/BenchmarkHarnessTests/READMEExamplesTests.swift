// The README's examples, verbatim, so the README cannot drift from the code.

import BenchmarkHarness
import Foundation
import Testing

@Suite("README examples")
struct READMEExamplesTests {
    @Test("Usage")
    func usage() throws {
        let iterations = [
            CallgrindDump(text: "events: Ir I1mr D1mr D1mw ILmr DLmr DLmw Bcm Bim\ntotals: 4100 2 9 3 0 1 0 12\n"),
            CallgrindDump(text: "events: Ir I1mr D1mr D1mw ILmr DLmr DLmw Bcm Bim\ntotals: 4100 0 8 3 0 0 0 12\n"),
        ]
        let overhead = [
            CallgrindDump(text: "events: Ir I1mr D1mr D1mw ILmr DLmr DLmw Bcm Bim\ntotals: 100\n"),
        ]
        let results = SimulatedMetric.allCases.map { metric in
            BenchmarkResult(metric: metric, iterations: iterations, overhead: overhead, warmupIterations: 1)
        }
        let baseline = BenchmarkBaseline(
            baselineName: "main",
            machine: BenchmarkMachine(hostname: "guest", processors: 8, processorType: "aarch64",
                                      memory: 8, kernelVersion: "6.12.28"),
            results: [BenchmarkIdentifier(target: "SortBenchmarks", name: "Sort 1000"): results]
        )
        let json = try JSONEncoder().encode(baseline)
        print(BenchmarkBaseline.relativePath(target: "SortBenchmarks", baselineName: "main"))
        // .benchmarkBaselines/SortBenchmarks/main/results.json

        #expect(results[0].statistics.valueAtPercentile(50) == 4000)
        #expect(!json.isEmpty)
    }

    @Test("Documentation overview")
    func overview() {
        let iterations = [
            CallgrindDump(text: "events: Ir I1mr D1mr D1mw ILmr DLmr DLmw Bcm Bim\ntotals: 4100 2 9 3 0 1 0 12\n"),
        ]
        let overhead = [
            CallgrindDump(text: "events: Ir I1mr D1mr D1mw ILmr DLmr DLmw Bcm Bim\ntotals: 100\n"),
        ]
        let result = BenchmarkResult(metric: .instructions, iterations: iterations, overhead: overhead, warmupIterations: 0)
        print(result.statistics.valueAtPercentile(50))  // 4000

        let expected: UInt64 = 4000
        #expect(result.statistics.valueAtPercentile(50) == expected)
    }
}
