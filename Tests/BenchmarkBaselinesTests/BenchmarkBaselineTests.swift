// Each test is self-contained: it builds its own values and states its own expectations, so it
// can be copied into another file and still run. Nothing here is shared but the imports.
//
// The expected JSON comes from ordo-one/benchmark 1.38.0: `swift package benchmark baseline update`
// on a benchmark recording `.custom("Large count")` as 123_456_789 and `.custom("Example count")`
// as 42 in each of five iterations after one warmup.

import BenchmarkBaselines
import BenchmarkHarnessTestSupport
import Foundation
import Testing

@Suite("BenchmarkBaseline: hand-worked cases")
struct BenchmarkBaselineTests {
    @Test("A result encodes as ordo-one/benchmark 1.38.0 encodes the same measurements", .tags(.fixture))
    func resultMatchesOrdoOne() throws {
        let result = BenchmarkResult(
            metric: .custom("Large count"),
            measurements: repeatElement(UInt64(123_456_789), count: 5),
            warmupIterations: 1
        )
        let data = try JSONEncoder().encode(result)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let statistics = try #require(object["statistics"] as? [String: Any])
        let histogram = try #require(statistics["histogram"] as? [String: Any])
        let counts = try #require(histogram["counts"] as? [Int])
        let metric = try #require(object["metric"] as? [String: Any])
        let custom = try #require(metric["custom"] as? [String: Any])
        let polarity = try #require(custom["polarity"] as? [String: Any])

        let expectedName = "Large count"
        let expectedTimeUnits = "milliseconds"
        let expectedCacheUnits = 1_000_000
        let expectedCountsLength = 21504
        let expectedNonZeroCounts: [Int: Int] = [18267: 5]
        let expectedHistogramFields: [String: Int] = [
            "maxValue": 123_456_789, "unitMagnitude": 0, "subBucketMask": 2047, "lowestDiscernibleValue": 1,
            "highestTrackableValue": 1_000_000_000, "subBucketHalfCountMagnitude": 10, "minNonZeroValue": 123_456_789,
            "leadingZeroCountBase": 53, "_totalCount": 5, "numberOfSignificantValueDigits": 3, "bucketCount": 20,
        ]
        let expectedKeys: Set<String> = ["metric", "timeUnits", "scalingFactor", "warmupIterations", "tags", "statistics"]

        #expect(Set(object.keys) == expectedKeys)
        #expect(custom["_0"] as? String == expectedName)
        #expect(custom["useScalingFactor"] as? Bool == true)
        #expect(Set(polarity.keys) == ["prefersSmaller"])
        #expect(object["timeUnits"] as? String == expectedTimeUnits)
        #expect(object["scalingFactor"] as? Int == 1)
        #expect(object["warmupIterations"] as? Int == 1)
        #expect((object["tags"] as? [String: String])?.isEmpty == true)
        #expect(statistics["_cacheUnits"] as? Int == expectedCacheUnits)
        #expect(statistics["_cachedPercentilesHistogramCount"] as? Int == 5)
        #expect((statistics["_cachedPercentiles"] as? [Int])?.isEmpty == true)
        #expect(statistics["timeUnits"] as? Int == 0)
        #expect(statistics["prefersLarger"] as? Bool == false)
        #expect(histogram["autoResize"] as? Bool == true)
        for (key, value) in expectedHistogramFields.sorted(by: { $0.key < $1.key }) {
            #expect(histogram[key] as? Int == value, "\(key)")
        }
        #expect(counts.count == expectedCountsLength)
        let nonZero = Dictionary(uniqueKeysWithValues: counts.enumerated().filter { $0.element != 0 }.map { ($0.offset, $0.element) })
        #expect(nonZero == expectedNonZeroCounts)
    }

    @Test("Small measurements display in count units, as ordo-one/benchmark 1.38.0 does", .tags(.fixture))
    func smallResultMatchesOrdoOne() throws {
        let result = BenchmarkResult(
            metric: .custom("Example count"),
            measurements: repeatElement(UInt64(42), count: 5),
            warmupIterations: 1
        )
        let data = try JSONEncoder().encode(result)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let statistics = try #require(object["statistics"] as? [String: Any])
        let histogram = try #require(statistics["histogram"] as? [String: Any])
        let counts = try #require(histogram["counts"] as? [Int])
        let expectedNonZeroCounts: [Int: Int] = [42: 5]
        #expect(object["timeUnits"] as? String == "nanoseconds")
        #expect(statistics["_cacheUnits"] as? Int == 1)
        let nonZero = Dictionary(uniqueKeysWithValues: counts.enumerated().filter { $0.element != 0 }.map { ($0.offset, $0.element) })
        #expect(nonZero == expectedNonZeroCounts)
    }

    @Test("The instruction count metric encodes as ordo-one/benchmark's", .tags(.fixture))
    func instructionsMetric() throws {
        let data = try JSONEncoder().encode(BenchmarkMetric.instructions)
        let expected = #"{"instructions":{}}"#
        #expect(String(decoding: data, as: UTF8.self) == expected)
    }

    @Test("A metric round-trips through JSON", .tags(.conformance))
    func metricCoding() throws {
        let metrics: [BenchmarkMetric] = [
            .instructions,
            .custom("Cycle Estimation"),
            .custom("Throughput", polarity: .prefersLarger, useScalingFactor: false),
        ]
        let decoded = try JSONDecoder().decode([BenchmarkMetric].self, from: JSONEncoder().encode(metrics))
        #expect(decoded == metrics)
        #expect(metrics.map(\.prefersLarger) == [false, false, true])
    }

    @Test("A baseline encodes its results as identifiers alternating with their results, sorted")
    func baselineLayout() throws {
        let machine = BenchmarkMachine(hostname: "guest", processors: 8, processorType: "aarch64", memory: 8, kernelVersion: "6.12.28")
        let later = BenchmarkIdentifier(target: "B", name: "a")
        let earlier = BenchmarkIdentifier(target: "A", name: "z")
        let baseline = BenchmarkBaseline(
            baselineName: "main",
            machine: machine,
            results: [
                later: [BenchmarkResult(metric: .instructions, measurements: [1], warmupIterations: 0)],
                earlier: [BenchmarkResult(metric: .instructions, measurements: [2], warmupIterations: 0)],
            ]
        )
        let data = try JSONEncoder().encode(baseline)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let results = try #require(object["results"] as? [Any])
        let first = try #require(results[0] as? [String: String])
        let third = try #require(results[2] as? [String: String])
        let expectedMachine: [String: AnyHashable] = [
            "hostname": "guest", "processors": 8, "processorType": "aarch64", "memory": 8, "kernelVersion": "6.12.28",
        ]
        #expect(Set(object.keys) == ["baselineName", "machine", "results"])
        #expect(object["baselineName"] as? String == "main")
        #expect((object["machine"] as? [String: AnyHashable]) == expectedMachine)
        #expect(results.count == 4)
        #expect(first == ["target": "A", "name": "z"])
        #expect(third == ["target": "B", "name": "a"])
        #expect((results[1] as? [Any])?.count == 1)
    }

    @Test("An empty baseline encodes an empty results array")
    func emptyBaseline() throws {
        let machine = BenchmarkMachine(hostname: "h", processors: 1, processorType: "aarch64", memory: 1, kernelVersion: "k")
        let baseline = BenchmarkBaseline(baselineName: "empty", machine: machine, results: [:])
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(baseline)) as? [String: Any])
        #expect((object["results"] as? [Any])?.isEmpty == true)
        #expect(baseline.byTarget.isEmpty)
    }

    @Test("byTarget splits a baseline into one per benchmark target")
    func byTarget() {
        let machine = BenchmarkMachine(hostname: "h", processors: 1, processorType: "aarch64", memory: 1, kernelVersion: "k")
        let a1 = BenchmarkIdentifier(target: "A", name: "1")
        let a2 = BenchmarkIdentifier(target: "A", name: "2")
        let b1 = BenchmarkIdentifier(target: "B", name: "1")
        let result = [BenchmarkResult(metric: .instructions, measurements: [5], warmupIterations: 0)]
        let baseline = BenchmarkBaseline(baselineName: "main", machine: machine, results: [a1: result, a2: result, b1: result])
        let split = baseline.byTarget
        #expect(split.keys.sorted() == ["A", "B"])
        #expect(split["A"]?.results.keys.sorted() == [a1, a2])
        #expect(split["B"]?.results.keys.sorted() == [b1])
        #expect(split["A"]?.baselineName == "main")
    }

    @Test("The baseline file lives where ordo-one/benchmark reads it")
    func relativePath() {
        let expected = ".benchmarkBaselines/SortBenchmarks/main/results.json"
        #expect(BenchmarkBaseline.relativePath(target: "SortBenchmarks", baselineName: "main") == expected)
    }

    @Test("Identifiers order by target, then name", .tags(.conformance))
    func identifierOrder() {
        let identifiers = [
            BenchmarkIdentifier(target: "B", name: "a"),
            BenchmarkIdentifier(target: "A", name: "b"),
            BenchmarkIdentifier(target: "A", name: "a"),
        ]
        let expected = [
            BenchmarkIdentifier(target: "A", name: "a"),
            BenchmarkIdentifier(target: "A", name: "b"),
            BenchmarkIdentifier(target: "B", name: "a"),
        ]
        #expect(identifiers.sorted() == expected)
    }

    @Test("A baseline name that is empty or holds a slash traps", .tags(.precondition))
    func badNamesTrap() async {
        await #expect(processExitsWith: .failure) {
            let machine = BenchmarkMachine(hostname: "h", processors: 1, processorType: "a", memory: 1, kernelVersion: "k")
            _ = BenchmarkBaseline(baselineName: "", machine: machine, results: [:])
        }
        await #expect(processExitsWith: .failure) {
            let machine = BenchmarkMachine(hostname: "h", processors: 1, processorType: "a", memory: 1, kernelVersion: "k")
            _ = BenchmarkBaseline(baselineName: "a/b", machine: machine, results: [:])
        }
    }

    @Test("Negative warmup iterations trap", .tags(.precondition))
    func negativeWarmupTraps() async {
        await #expect(processExitsWith: .failure) {
            _ = BenchmarkResult(metric: .instructions, measurements: [1], warmupIterations: -1)
        }
    }
}
