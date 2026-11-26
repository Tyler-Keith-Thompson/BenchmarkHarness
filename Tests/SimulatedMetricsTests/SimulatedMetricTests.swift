// Each test is self-contained: it builds its own values and states its own expectations, so it
// can be copied into another file and still run. Nothing here is shared but the imports.

import BenchmarkBaselines
import BenchmarkHarnessTestSupport
import Callgrind
import PropertyBased
import SimulatedMetrics
import Testing

@Suite("SimulatedMetric")
struct SimulatedMetricTests {
    @Test("Each metric sums its events, and the cycle estimation weights misses as KCachegrind does")
    func handWorked() throws {
        // Ir Dr Dw I1mr D1mr D1mw ILmr DLmr DLmw Bc Bcm Bi Bim
        let dump = try CallgrindDump(text: "events: Ir Dr Dw I1mr D1mr D1mw ILmr DLmr DLmw Bc Bcm Bi Bim\ntotals: 1000 400 200 3 5 7 1 2 4 90 11 6 2\n")
        let level1: UInt64 = 3 + 5 + 7
        let lastLevel: UInt64 = 1 + 2 + 4
        let branches: UInt64 = 11 + 2
        let cycles: UInt64 = 1000 + 10 * branches + 10 * level1 + 100 * lastLevel
        #expect(try SimulatedMetric.instructions.value(in: dump) == 1000)
        #expect(try SimulatedMetric.level1MissSum.value(in: dump) == level1)
        #expect(try SimulatedMetric.lastLevelMissSum.value(in: dump) == lastLevel)
        #expect(try SimulatedMetric.mispredictedBranches.value(in: dump) == branches)
        #expect(try SimulatedMetric.cycleEstimation.value(in: dump) == cycles)
    }

    @Test("Every metric of an all-zero dump is zero", .tags(.exhaustive))
    func zeros() throws {
        let dump = try CallgrindDump(text: "events: Ir I1mr D1mr D1mw ILmr DLmr DLmw Bcm Bim\ntotals:\n")
        for metric in SimulatedMetric.allCases {
            #expect(try metric.value(in: dump) == 0, "\(metric)")
        }
    }

    @Test("Instructions are ordo-one/benchmark's built-in metric; the rest are custom, named as in KCachegrind", .tags(.exhaustive))
    func benchmarkMetrics() {
        let expected: [SimulatedMetric: BenchmarkMetric] = [
            .instructions: .instructions,
            .level1MissSum: .custom("L1 Miss Sum"),
            .lastLevelMissSum: .custom("Last-level Miss Sum"),
            .mispredictedBranches: .custom("Mispredicted Branch"),
            .cycleEstimation: .custom("Cycle Estimation"),
        ]
        for metric in SimulatedMetric.allCases {
            #expect(metric.benchmarkMetric == expected[metric], "\(metric)")
        }
    }

    @Test("A result subtracts the median overhead from each iteration and clamps at zero")
    func overheadSubtracted() throws {
        func dump(_ instructions: Int) throws -> CallgrindDump {
            try CallgrindDump(text: "events: Ir I1mr D1mr D1mw ILmr DLmr DLmw Bcm Bim\ntotals: \(instructions)\n")
        }
        let iterations = try [dump(1500), dump(1100), dump(90)]
        let overhead = try [dump(120), dump(100), dump(80), dump(300)]
        let result = try BenchmarkResult(metric: .instructions, iterations: iterations, overhead: overhead, warmupIterations: 1)
        // The lower median of 80, 100, 120, 300 is 100.
        let expected = Statistics(measurements: [1400, 1000, 0])
        #expect(result.statistics == expected)
        #expect(result.metric == .instructions)
        #expect(result.warmupIterations == 1)
    }

    @Test("With no overhead dumps nothing is subtracted, and with no iterations the result is empty")
    func emptyInputs() throws {
        let dump = try CallgrindDump(text: "events: Ir I1mr D1mr D1mw ILmr DLmr DLmw Bcm Bim\ntotals: 700\n")
        let unadjusted = try BenchmarkResult(metric: .instructions, iterations: [dump], overhead: [], warmupIterations: 0)
        let empty = try BenchmarkResult(metric: .instructions, iterations: [], overhead: [dump], warmupIterations: 0)
        #expect(unadjusted.statistics == Statistics(measurements: [700]))
        #expect(empty.statistics.measurementCount == 0)
    }

    @Test("A dump missing a required event throws MissingRequiredEvent")
    func missingEventThrows() throws {
        let dump = try CallgrindDump(text: "events: Ir\ntotals: 5\n")

        #expect(throws: MissingRequiredEvent()) {
            try SimulatedMetric.cycleEstimation.value(in: dump)
        }
    }

    @Test("Instructions read only Ir, so a dump counting Ir alone gives instructions but throws for the others")
    func instructionsReadOnlyIr() throws {
        let dump = try CallgrindDump(text: "events: Ir\ntotals: 5\n")
        let expected: UInt64 = 5

        let actual = try SimulatedMetric.instructions.value(in: dump)

        #expect(actual == expected)
        for metric in [SimulatedMetric.level1MissSum, .lastLevelMissSum, .mispredictedBranches] {
            #expect(throws: MissingRequiredEvent(), "\(metric)") {
                try metric.value(in: dump)
            }
        }
    }

    @Test("A result throws missingRequiredEvent when an iteration or overhead dump lacks a required event")
    func resultMissingEventThrows() throws {
        let complete = try CallgrindDump(text: "events: Ir I1mr D1mr D1mw ILmr DLmr DLmw Bcm Bim\ntotals: 700\n")
        let incomplete = try CallgrindDump(text: "events: Ir\ntotals: 700\n")

        #expect(throws: InvalidSimulatedResult.missingRequiredEvent) {
            try BenchmarkResult(metric: .cycleEstimation, iterations: [incomplete], overhead: [complete], warmupIterations: 0)
        }
        #expect(throws: InvalidSimulatedResult.missingRequiredEvent) {
            try BenchmarkResult(metric: .cycleEstimation, iterations: [complete], overhead: [incomplete], warmupIterations: 0)
        }
    }

    @Test("A result throws negativeWarmupIterations for a negative warmup count, and takes zero")
    func resultNegativeWarmupThrows() throws {
        let dump = try CallgrindDump(text: "events: Ir I1mr D1mr D1mw ILmr DLmr DLmw Bcm Bim\ntotals: 700\n")
        let expectedWarmup = 0

        let actual = try BenchmarkResult(metric: .instructions, iterations: [dump], overhead: [], warmupIterations: 0)

        #expect(actual.warmupIterations == expectedWarmup)
        #expect(throws: InvalidSimulatedResult.negativeWarmupIterations) {
            try BenchmarkResult(metric: .instructions, iterations: [dump], overhead: [], warmupIterations: -1)
        }
    }

    @Test("Metric values match a naive reference over the raw totals", .tags(.randomized))
    func agreesWithReference() async {
        let totals = Gen.int(in: 0 ... 10_000_000).array(of: 13)
        await propertyCheck(count: 300, input: totals) { totals in
            let names = ["Ir", "Dr", "Dw", "I1mr", "D1mr", "D1mw", "ILmr", "DLmr", "DLmw", "Bc", "Bcm", "Bi", "Bim"]
            let dump = try CallgrindDump(text: "events: \(names.joined(separator: " "))\ntotals: \(totals.map(String.init).joined(separator: " "))\n")
            let total = Dictionary(uniqueKeysWithValues: zip(names, totals.map(UInt64.init)))
            let level1 = total["I1mr"]! + total["D1mr"]! + total["D1mw"]!
            let lastLevel = total["ILmr"]! + total["DLmr"]! + total["DLmw"]!
            let branches = total["Bcm"]! + total["Bim"]!
            #expect(try SimulatedMetric.instructions.value(in: dump) == total["Ir"]!)
            #expect(try SimulatedMetric.cycleEstimation.value(in: dump) == total["Ir"]! + 10 * (level1 + branches) + 100 * lastLevel)
        }
    }

    @Test("requiredEvents are exactly the events the metrics read", .tags(.exhaustive))
    func requiredEvents() throws {
        let expected: Set<String> = ["Ir", "I1mr", "D1mr", "D1mw", "ILmr", "DLmr", "DLmw", "Bcm", "Bim"]
        #expect(Set(SimulatedMetric.requiredEvents.map(\.rawValue)) == expected)
        let dump = try CallgrindDump(text: "events: \(expected.sorted().joined(separator: " "))\ntotals:\n")
        for metric in SimulatedMetric.allCases {
            #expect(try metric.value(in: dump) == 0)
        }
    }
}
