import Benchmark

// A fixture for benchmark-harness rather than a benchmark of the library: one iteration of about
// 1.3 billion instructions, a naive scan of a thousand byte patterns at every offset of a 10⁵-byte
// text, in tight loops that make no calls, after a registration that builds 10⁵ strings. Under
// Callgrind each iteration takes about a minute, and a simulated run of it must finish.

let benchmarks: @Sendable () -> Void = {
    Benchmark.defaultConfiguration.metrics = [.wallClock, .mallocCountTotal, .instructions]
    Benchmark.defaultConfiguration.maxDuration = .seconds(2)

    // A seeded linear congruential generator, so every run sees the same text and patterns.
    var state: UInt64 = 1
    func next(below bound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int(truncatingIfNeeded: state >> 33) % bound
    }
    func word(length: Int) -> String {
        String((0 ..< length).map { _ in Character(Unicode.Scalar(UInt8(97 + next(below: 26)))) })
    }
    let words = (0 ..< 100_000).map { _ in word(length: 3 + next(below: 8)) }
    let sorted = Array(Set(words)).sorted()

    // 1000 patterns of four to eight letters, and a text of 10⁵ letters and spaces with a pattern
    // planted about every 200 symbols.
    let patterns = (0 ..< 1_000).map { _ in word(length: 4 + next(below: 5)) }
    var haystack = ""
    while haystack.utf8.count < 100_000 {
        if next(below: 200) == 0 {
            haystack += patterns[next(below: patterns.count)]
        } else {
            haystack.append(next(below: 6) == 0 ? " " : Character(Unicode.Scalar(UInt8(97 + next(below: 26)))))
        }
    }
    let haystackBytes = Array(haystack.utf8)
    let patternBytes = patterns.map { Array($0.utf8) }

    Benchmark("Long iteration: sorted words") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(sorted.count)
        }
    }

    Benchmark("Long iteration: naive scan for a thousand patterns at every offset") { benchmark in
        for _ in benchmark.scaledIterations {
            var found = 0
            haystackBytes.withUnsafeBufferPointer { text in
                for pattern in patternBytes {
                    pattern.withUnsafeBufferPointer { pattern in
                        var start = 0
                        while start &+ pattern.count <= text.count {
                            var k = 0
                            while k < pattern.count && text[start &+ k] == pattern[k] {
                                k &+= 1
                            }
                            if k == pattern.count { found &+= 1 }
                            start &+= 1
                        }
                    }
                }
            }
            blackHole(found)
        }
    }
}
