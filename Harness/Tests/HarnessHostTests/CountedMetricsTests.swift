// Each test is self-contained: it builds its own values and states its own expectations, so it
// can be copied into another file and still run. Nothing here is shared but the imports.

import BenchmarkBaselines
import BenchmarkCommands
import Foundation
import HarnessHost
import Testing

@Suite("Counted metrics")
struct CountedMetricsTests {
    @Test("Allocation, reference-count and custom metrics are counted, in the benchmark's order; time, memory and system metrics are not")
    func selection() throws {
        let json = Data(#"""
            {"name": "B", "configuration": {"metrics": [
                {"wallClock": {}}, {"retainCount": {}}, {"throughput": {}}, {"mallocCountTotal": {}},
                {"peakMemoryResident": {}}, {"syscalls": {}}, {"instructions": {}}, {"cpuTotal": {}},
                {"custom": {"_0": "Nodes", "polarity": {"prefersSmaller": {}}, "useScalingFactor": true}},
                {"releaseCount": {}}, {"memoryLeaked": {}}
            ]}}
            """#.utf8)
        let benchmark = try Benchmark(json: json)
        let expected: [BenchmarkMetric] = [.retainCount, .mallocCountTotal, .custom("Nodes"), .releaseCount, .memoryLeaked]
        #expect(SimulatedBaselineRecorder.countedMetrics(of: benchmark) == expected)
    }

    @Test("Every allocation and reference-count metric ordo-one/benchmark defines is counted", .tags(.exhaustive))
    func everyCountedMetric() throws {
        let names = [
            "mallocCountSmall", "mallocCountLarge", "mallocCountTotal", "freeCountTotal", "mallocBytesCount",
            "mallocFreeDelta", "memoryLeaked", "memoryLeakedBytes", "objectAllocCount", "retainCount",
            "releaseCount", "retainReleaseDelta",
        ]
        let metrics = names.map { #"{"\#($0)": {}}"# }.joined(separator: ", ")
        let benchmark = try Benchmark(json: Data(#"{"name": "B", "configuration": {"metrics": [\#(metrics)]}}"#.utf8))
        let expectedCount = 12
        #expect(SimulatedBaselineRecorder.countedMetrics(of: benchmark).count == expectedCount)
    }

    @Test("A benchmark with no metrics has no counted metrics")
    func noMetrics() throws {
        let benchmark = try Benchmark(json: Data(#"{"name": "B", "configuration": {}}"#.utf8))
        #expect(SimulatedBaselineRecorder.countedMetrics(of: benchmark).isEmpty)
    }
}

extension Tag {
    @Tag static var exhaustive: Self
}
