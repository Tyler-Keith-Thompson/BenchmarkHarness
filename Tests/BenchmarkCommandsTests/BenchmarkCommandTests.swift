// Each test is self-contained: it builds its own values and states its own expectations, so it
// can be copied into another file and still run. Nothing here is shared but the imports.
//
// The reply JSON is what an ordo-one/benchmark 1.38.0 executable wrote in reply to `list`.

import BenchmarkBaselines
import BenchmarkCommands
import BenchmarkHarnessTestSupport
import Foundation
import Testing

@Suite("BenchmarkCommandRequest, BenchmarkCommandReply and Benchmark: hand-worked cases")
struct BenchmarkCommandTests {
    @Test("A list reply written by ordo-one/benchmark 1.38.0 decodes to its benchmark", .tags(.fixture))
    func listReply() throws {
        let json = Data(#"""
            {"list": {"benchmark": {"target": "", "name": "Sum1000", "configuration": {"timeUnits": "automatic", "scalingFactor": 1, "maxDuration": [0, 1000000000000000000], "maxIterations": 20, "tags": {}, "units": [], "metrics": [{"wallClock": {}}, {"instructions": {}}], "warmupIterations": 1}}}}
            """#.utf8)
        let reply = try BenchmarkCommandReply(json: json)
        guard case let .list(benchmark) = reply else {
            Issue.record("Expected a list reply, got \(reply)")
            return
        }
        let expectedName = "Sum1000"
        let expectedWarmup = 1
        #expect(benchmark.name == expectedName)
        #expect(benchmark.warmupIterations == expectedWarmup)
    }

    @Test("measuring(_:) replaces the metrics and keeps every other setting")
    func measuringReplacesMetrics() throws {
        let original = try Benchmark(json: Data(#"""
            {"target": "T", "name": "Sort", "configuration": {"maxIterations": 20, "metrics": [{"wallClock": {}}], "warmupIterations": 2}}
            """#.utf8))
        let measured = original.measuring([.instructions])
        let object = try #require(try JSONSerialization.jsonObject(with: measured.json) as? [String: Any])
        let configuration = try #require(object["configuration"] as? [String: Any])
        let metrics = try #require(configuration["metrics"] as? [[String: Any]])
        #expect(metrics.count == 1)
        #expect(metrics.first.map { Set($0.keys) } == ["instructions"])
        #expect(configuration["maxIterations"] as? Int == 20)
        #expect(object["target"] as? String == "T")
        #expect(measured.name == "Sort")
        #expect(measured.warmupIterations == 2)
    }

    @Test("measuring(_:) with no metrics leaves an empty list")
    func measuringNothing() throws {
        let original = try Benchmark(json: Data(#"{"name": "A", "configuration": {"metrics": [{"wallClock": {}}]}}"#.utf8))
        let object = try #require(try JSONSerialization.jsonObject(with: original.measuring([]).json) as? [String: Any])
        let configuration = try #require(object["configuration"] as? [String: Any])
        #expect((configuration["metrics"] as? [Any])?.isEmpty == true)
        #expect(original.warmupIterations == 0)
    }

    @Test("Requests encode as ordo-one/benchmark's BenchmarkCommandRequest", .tags(.fixture))
    func requestJSON() throws {
        let benchmark = try Benchmark(json: Data(#"{"name":"A","configuration":{}}"#.utf8))
        let list = #"{"list":{}}"#
        let end = #"{"end":{}}"#
        let run = #"{"run":{"benchmark":{"name":"A","configuration":{}}}}"#
        #expect(String(decoding: BenchmarkCommandRequest.list.json, as: UTF8.self) == list)
        #expect(String(decoding: BenchmarkCommandRequest.end.json, as: UTF8.self) == end)
        #expect(String(decoding: BenchmarkCommandRequest.run(benchmark: benchmark).json, as: UTF8.self) == run)
    }

    @Test("A frame is the JSON's length as 8 little-endian bytes, then the JSON")
    func frameLayout() {
        let frame = BenchmarkCommandRequest.list.frame
        let expectedPrefix: [UInt8] = [11, 0, 0, 0, 0, 0, 0, 0]
        #expect(Array(frame.prefix(8)) == expectedPrefix)
        #expect(frame.dropFirst(8) == BenchmarkCommandRequest.list.json)
    }

    @Test("Every reply case decodes", .tags(.exhaustive))
    func everyReply() throws {
        let benchmark = #"{"name":"A","configuration":{}}"#
        let expected: [(String, BenchmarkCommandReply)] = try [
            (#"{"list":{"benchmark":\#(benchmark)}}"#, .list(benchmark: Benchmark(json: Data(benchmark.utf8)))),
            (#"{"ready":{}}"#, .ready),
            (#"{"result":{"benchmark":\#(benchmark),"results":[]}}"#, .result(benchmark: Benchmark(json: Data(benchmark.utf8)))),
            (#"{"allocationStacks":{"benchmark":\#(benchmark),"report":{}}}"#, .allocationStacks(benchmark: Benchmark(json: Data(benchmark.utf8)))),
            (#"{"run":{}}"#, .run),
            (#"{"end":{}}"#, .end),
            (#"{"error":{"_0":"Benchmark setup failed"}}"#, .error("Benchmark setup failed")),
        ]
        for (json, reply) in expected {
            let decoded = try BenchmarkCommandReply(json: Data(json.utf8))
            switch (decoded, reply) {
            case let (.list(a), .list(b)), let (.result(a), .result(b)), let (.allocationStacks(a), .allocationStacks(b)):
                #expect(a.name == b.name, "\(json)")
            default:
                #expect(decoded == reply, "\(json)")
            }
        }
    }

    @Test("Bytes that are not a reply or benchmark throw MalformedBenchmarkCommand")
    func malformed() {
        let replies = [
            "", "[]", "{}", #"{"list":{}}"#, #"{"unknown":{}}"#, #"{"end":{},"run":{}}"#, #"{"error":{}}"#,
            #"{"list":{"benchmark":{"configuration":{}}}}"#, #"{"list":{"benchmark":{"name":"A"}}}"#,
        ]
        for json in replies {
            #expect(throws: MalformedBenchmarkCommand(), "\(json)") {
                try BenchmarkCommandReply(json: Data(json.utf8))
            }
        }
        #expect(throws: MalformedBenchmarkCommand()) {
            try Benchmark(json: Data("not json".utf8))
        }
    }
}
