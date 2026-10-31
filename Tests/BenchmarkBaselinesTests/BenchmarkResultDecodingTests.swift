// Each test is self-contained: it builds its own values and states its own expectations, so it
// can be copied into another file and still run. Nothing here is shared but the imports.
//
// The fixture is a result ordo-one/benchmark 1.38.0 wrote for a custom metric measured five times
// at 123456789 with one warmup iteration. Its histogram's 21504 counts are all zero but index
// 18267, so the JSON is rebuilt here from its fields rather than pasted.

import BenchmarkBaselines
import BenchmarkHarnessTestSupport
import Foundation
import PropertyBased
import Testing

@Suite("BenchmarkResult and Statistics decoding: hand-worked cases")
struct BenchmarkResultDecodingTests {
    @Test("A result ordo-one/benchmark 1.38.0 wrote decodes to its metric, warmup, scaling factor and measurements", .tags(.fixture))
    func decodesOrdoOneResult() throws {
        var counts = [Int](repeating: 0, count: 21504)
        counts[18267] = 5
        let histogram: [String: Any] = [
            "unitMagnitude": 0, "leadingZeroCountBase": 53, "maxValue": 123_456_789, "subBucketMask": 2047,
            "bucketCount": 20, "autoResize": true, "_totalCount": 5, "subBucketHalfCountMagnitude": 10,
            "numberOfSignificantValueDigits": 3, "highestTrackableValue": 1_000_000_000,
            "minNonZeroValue": 123_456_789, "lowestDiscernibleValue": 1, "counts": counts,
        ]
        let result: [String: Any] = [
            "metric": ["custom": ["useScalingFactor": true, "_0": "Large count", "polarity": ["prefersSmaller": [String: Any]()]]],
            "scalingFactor": 1, "timeUnits": "milliseconds", "warmupIterations": 1, "tags": [String: String](),
            "statistics": [
                "_cachedPercentiles": [Int](), "timeUnits": 0, "_cacheUnits": 1_000_000,
                "_cachedPercentilesHistogramCount": 5, "prefersLarger": false, "histogram": histogram,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: result)
        let decoded = try JSONDecoder().decode(BenchmarkResult.self, from: data)
        let expectedMetric = BenchmarkMetric.custom("Large count")
        let expectedMedian: UInt64 = 123_456_789
        let tolerance: UInt64 = 123_457 // three significant digits
        let expectedCount = 5
        let expectedScaling = 1
        let expectedWarmup = 1
        #expect(decoded.metric == expectedMetric)
        #expect(decoded.warmupIterations == expectedWarmup)
        #expect(decoded.scalingFactor == expectedScaling)
        #expect(decoded.statistics.measurementCount == expectedCount)
        #expect(decoded.statistics.valueAtPercentile(50).distance(to: expectedMedian).magnitude <= tolerance)
        #expect(decoded.statistics.prefersLarger == false)
        #expect(decoded.timeUnits == "milliseconds")
    }

    @Test("A result decodes back to the result it was encoded from")
    func roundTrip() throws {
        let result = BenchmarkResult(metric: .mallocCountTotal, measurements: [3, 3, 4, 7], warmupIterations: 2)
        let decoded = try JSONDecoder().decode(BenchmarkResult.self, from: JSONEncoder().encode(result))
        #expect(decoded == result)
    }

    @Test("A decoded scaling factor is kept and encoded again")
    func keepsScalingFactor() throws {
        let result = BenchmarkResult(metric: .retainCount, measurements: [1000], warmupIterations: 0)
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        object["scalingFactor"] = 1000
        let decoded = try JSONDecoder().decode(BenchmarkResult.self, from: JSONSerialization.data(withJSONObject: object))
        let reencoded = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        let expectedScaling = 1000
        #expect(decoded.scalingFactor == expectedScaling)
        #expect(reencoded["scalingFactor"] as? Int == expectedScaling)
    }

    @Test("A results' scaling factor that ordo-one/benchmark does not define, or a negative warmup, throws")
    func rejectsInvalidFields() throws {
        let result = BenchmarkResult(metric: .instructions, measurements: [1], warmupIterations: 0)
        let encoded = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        for (key, value) in [("scalingFactor", 0), ("scalingFactor", 10), ("scalingFactor", -1), ("warmupIterations", -1)] {
            var object = encoded
            object[key] = value
            let data = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: DecodingError.self, "\(key) \(value)") {
                try JSONDecoder().decode(BenchmarkResult.self, from: data)
            }
        }
    }

    @Test("Every scaling factor ordo-one/benchmark defines, from one to tera, decodes", .tags(.exhaustive))
    func everyScalingFactor() throws {
        let result = BenchmarkResult(metric: .instructions, measurements: [1], warmupIterations: 0)
        let encoded = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        for factor in [1, 1_000, 1_000_000, 1_000_000_000, 1_000_000_000_000] {
            var object = encoded
            object["scalingFactor"] = factor
            let decoded = try JSONDecoder().decode(BenchmarkResult.self, from: JSONSerialization.data(withJSONObject: object))
            #expect(decoded.scalingFactor == factor)
        }
    }

    @Test("Every built-in metric encodes as ordo-one/benchmark 1.38.0 names it, and decodes back", .tags(.exhaustive, .fixture))
    func everyMetric() throws {
        let metrics: [(BenchmarkMetric, String)] = [
            (.cpuUser, "cpuUser"), (.cpuSystem, "cpuSystem"), (.cpuTotal, "cpuTotal"), (.wallClock, "wallClock"),
            (.throughput, "throughput"), (.peakMemoryResident, "peakMemoryResident"),
            (.peakMemoryResidentDelta, "peakMemoryResidentDelta"), (.peakMemoryVirtual, "peakMemoryVirtual"),
            (.mallocCountSmall, "mallocCountSmall"), (.mallocCountLarge, "mallocCountLarge"),
            (.mallocCountTotal, "mallocCountTotal"), (.freeCountTotal, "freeCountTotal"),
            (.mallocBytesCount, "mallocBytesCount"), (.mallocFreeDelta, "mallocFreeDelta"),
            (.allocatedResidentMemory, "allocatedResidentMemory"), (.memoryLeaked, "memoryLeaked"),
            (.memoryLeakedBytes, "memoryLeakedBytes"), (.syscalls, "syscalls"), (.contextSwitches, "contextSwitches"),
            (.threads, "threads"), (.threadsRunning, "threadsRunning"), (.readSyscalls, "readSyscalls"),
            (.writeSyscalls, "writeSyscalls"), (.readBytesLogical, "readBytesLogical"),
            (.writeBytesLogical, "writeBytesLogical"), (.readBytesPhysical, "readBytesPhysical"),
            (.writeBytesPhysical, "writeBytesPhysical"), (.instructions, "instructions"),
            (.objectAllocCount, "objectAllocCount"), (.retainCount, "retainCount"), (.releaseCount, "releaseCount"),
            (.retainReleaseDelta, "retainReleaseDelta"), (.delta, "delta"), (.deltaPercentage, "deltaPercentage"),
        ]
        let expectedCount = 34
        #expect(metrics.count == expectedCount)
        for (metric, name) in metrics {
            let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(metric)) as? [String: Any])
            #expect(Set(object.keys) == [name])
            #expect((object[name] as? [String: Any])?.isEmpty == true, "\(name)")
            #expect(try JSONDecoder().decode(BenchmarkMetric.self, from: Data(#"{"\#(name)":{}}"#.utf8)) == metric)
        }
    }

    @Test("Throughput and a custom metric preferring larger values prefer larger; every other metric smaller")
    func polarity() {
        let larger: [BenchmarkMetric] = [.throughput, .custom("Rate", polarity: .prefersLarger)]
        let smaller: [BenchmarkMetric] = [.instructions, .wallClock, .mallocCountTotal, .retainCount, .custom("Bytes"), .deltaPercentage]
        for metric in larger { #expect(metric.prefersLarger, "\(metric)") }
        for metric in smaller { #expect(!metric.prefersLarger, "\(metric)") }
    }

    @Test("Statistics with no measurements decode back to no measurements")
    func emptyStatistics() throws {
        let statistics = Statistics(measurements: [UInt64](), prefersLarger: true)
        let decoded = try JSONDecoder().decode(Statistics.self, from: JSONEncoder().encode(statistics))
        #expect(decoded == statistics)
        #expect(decoded.measurementCount == 0)
        #expect(decoded.prefersLarger)
    }

    @Test("A metric name ordo-one/benchmark does not define throws")
    func unknownMetric() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(BenchmarkMetric.self, from: Data(#"{"unknownMetric":{}}"#.utf8))
        }
    }
}

@Suite("BenchmarkResult and Statistics decoding: properties")
struct BenchmarkResultDecodingPropertyTests {
    @Test("Statistics decode to the same histogram, as a naive sorted median confirms", .tags(.randomized))
    func statisticsRoundTrip() async {
        let measurements = Gen.uint64(in: 0 ... 5_000_000_000).array(of: 1 ... 40)
        await propertyCheck(count: 200, input: measurements, Gen.bool) { measurements, prefersLarger in
            let statistics = Statistics(measurements: measurements, prefersLarger: prefersLarger)
            let decoded = try JSONDecoder().decode(Statistics.self, from: JSONEncoder().encode(statistics))
            #expect(decoded == statistics)
            #expect(decoded.measurementCount == measurements.count)
            let sorted = measurements.sorted()
            let median = sorted[(sorted.count - 1) / 2]
            // Three significant digits: the histogram's median is within a thousandth of the value.
            #expect(decoded.valueAtPercentile(50).distance(to: median).magnitude <= median / 1000 + 1)
        }
    }
}
