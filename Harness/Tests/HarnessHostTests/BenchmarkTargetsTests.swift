// Each test is self-contained: it builds its own values and states its own expectations, so it
// can be copied into another file and still run. Nothing here is shared but the imports.

import Foundation
import HarnessHost
import Testing

@Suite("Benchmark target discovery")
struct BenchmarkTargetsTests {
    @Test("Executable targets using BenchmarkPlugin are benchmark targets, as swift package dump-package lists them")
    func discovery() throws {
        let manifest = Data(#"""
            {"name": "Benchmarks", "targets": [
                {"name": "ZBenchmarks", "type": "executable", "pluginUsages": [{"plugin": ["BenchmarkPlugin", "benchmark"]}]},
                {"name": "ABenchmarks", "type": "executable", "pluginUsages": [{"plugin": ["BenchmarkPlugin", "package-benchmark"]}]},
                {"name": "Tool", "type": "executable", "pluginUsages": [{"plugin": ["Lint", null]}]},
                {"name": "Plain", "type": "executable"},
                {"name": "Library", "type": "regular", "pluginUsages": [{"plugin": ["BenchmarkPlugin", "benchmark"]}]}
            ]}
            """#.utf8)
        let expected = ["ABenchmarks", "ZBenchmarks"]
        #expect(try SimulatedBaselineRecorder.benchmarkTargets(inManifest: manifest) == expected)
    }

    @Test("A manifest with no targets has no benchmark targets")
    func noTargets() throws {
        let manifest = Data(#"{"name": "Empty", "targets": []}"#.utf8)
        #expect(try SimulatedBaselineRecorder.benchmarkTargets(inManifest: manifest).isEmpty)
    }

    @Test("Output that is not a manifest throws MalformedManifest")
    func malformed() {
        for text in ["", "{}", #"{"targets": 3}"#] {
            #expect(throws: MalformedManifest()) {
                try SimulatedBaselineRecorder.benchmarkTargets(inManifest: Data(text.utf8))
            }
        }
    }
}
