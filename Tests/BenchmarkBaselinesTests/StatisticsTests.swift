// Each test is self-contained: it builds its own values and states its own expectations, so it
// can be copied into another file and still run. Nothing here is shared but the imports.

import BenchmarkBaselines
import BenchmarkHarnessTestSupport
import Foundation
import PropertyBased
import Testing

@Suite("Statistics")
struct StatisticsTests {
    @Test("Units change at each power of a thousand above 10⁴", .tags(.exhaustive))
    func unitBoundaries() {
        let cases: [(Double, Statistics.Units)] = [
            (1, .count), (9999, .count), (10_000, .kilo), (9_999_999, .kilo), (10_000_000, .mega),
            (1e10, .giga), (1e13, .tera), (1e16, .peta), (1e20, .peta),
        ]
        for (mean, expected) in cases {
            #expect(Statistics.Units(fromMagnitudeOf: mean) == expected, "\(mean)")
        }
    }

    @Test("A mean of zero or below is in count units, and one that is not finite in kilo units")
    func degenerateMeans() {
        #expect(Statistics.Units(fromMagnitudeOf: 0) == .count)
        #expect(Statistics.Units(fromMagnitudeOf: -5) == .count)
        #expect(Statistics.Units(fromMagnitudeOf: .nan) == .kilo)
        #expect(Statistics.Units(fromMagnitudeOf: .infinity) == .kilo)
    }

    @Test("Measurements that are all zero are in count units")
    func allZero() {
        let statistics = Statistics(measurements: [0, 0, 0])
        #expect(statistics.units == .count)
        #expect(statistics.measurementCount == 3)
    }

    @Test("No measurements: count units, a count of zero")
    func empty() {
        let statistics = Statistics(measurements: [UInt64]())
        #expect(statistics.measurementCount == 0)
        #expect(statistics.units == .count)
    }

    @Test("A measurement above the initial maximum resizes the histogram rather than dropping it")
    func resizes() {
        let large: UInt64 = 50_000_000_000
        let statistics = Statistics(measurements: [large])
        #expect(statistics.measurementCount == 1)
        #expect(statistics.histogram.valuesAreEquivalent(statistics.valueAtPercentile(100), large))
    }

    @Test("Statistics of the same measurements are equal, in any order", .tags(.conformance))
    func equality() {
        #expect(Statistics(measurements: [1, 2, 3]) == Statistics(measurements: [3, 1, 2]))
        #expect(Statistics(measurements: [1, 2, 3]) != Statistics(measurements: [1, 2, 4]))
        #expect(Statistics(measurements: [1], prefersLarger: true) != Statistics(measurements: [1]))
    }

    @Test("The median matches a sorted-array median within the histogram's precision", .tags(.randomized))
    func medianAgreesWithReference() async {
        let values = Gen.int(in: 0 ... 10_000_000).array(of: 1 ... 200)
        await propertyCheck(count: 200, input: values) { values in
            let measurements = values.map(UInt64.init)
            let statistics = Statistics(measurements: measurements)
            let sorted = measurements.sorted()
            let reference = sorted[(sorted.count - 1) / 2]
            #expect(statistics.histogram.valuesAreEquivalent(statistics.valueAtPercentile(50), reference))
            #expect(statistics.measurementCount == values.count)
        }
    }

    @Test("Units follow the magnitude of the mean, as a naive reference computes it", .tags(.randomized))
    func unitsAgreeWithReference() async {
        let values = Gen.int(in: 1 ... 1_000_000_000).array(of: 1 ... 50)
        await propertyCheck(count: 200, input: values) { values in
            let statistics = Statistics(measurements: values.map(UInt64.init))
            let exponent = log10(statistics.histogram.mean)
            let expected: Statistics.Units = exponent < 4 ? .count : exponent < 7 ? .kilo : exponent < 10 ? .mega : .giga
            #expect(statistics.units == expected)
        }
    }
}
