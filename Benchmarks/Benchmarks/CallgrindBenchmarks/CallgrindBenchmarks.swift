import Benchmark
import Callgrind

let benchmarks: @Sendable () -> Void = {
    Benchmark.defaultConfiguration.metrics = [.wallClock, .instructions, .mallocCountTotal]
    Benchmark.defaultConfiguration.maxDuration = .seconds(2)
    Benchmark.defaultConfiguration.maxIterations = 50

    // A dump the size of one Callgrind writes per measured iteration: a header, a few hundred cost
    // lines, then the totals.
    let costLines = (0 ..< 400).map { "\($0) 12 3 1 0 0 0 0 0 0 2 0 1 0" }.joined(separator: "\n")
    let text = """
        version: 1
        creator: callgrind-3.28.0
        desc: Trigger: Client Request: iteration
        positions: line
        events: Ir Dr Dw I1mr D1mr D1mw ILmr DLmr DLmw Bc Bcm Bi Bim
        summary: 4800 1200 400 0 0 0 0 0 0 800 0 400 0
        fn=(1) main
        \(costLines)
        totals: 4800 1200 400 0 0 0 0 0 0 800 0 400 0
        """

    // The hand-written form the library must keep pace with: find the two lines, split them.
    Benchmark("Callgrind: BASELINE split the events and totals lines") { benchmark in
        for _ in benchmark.scaledIterations {
            var events: [Substring] = []
            var totals: [Int] = []
            for line in text.split(separator: "\n") {
                if line.hasPrefix("events:") {
                    events = line.dropFirst(7).split(separator: " ")
                } else if line.hasPrefix("totals:") {
                    totals = line.dropFirst(7).split(separator: " ").compactMap { Int($0) }
                }
            }
            blackHole(events)
            blackHole(totals)
        }
    }

    Benchmark("Callgrind: CallgrindDump(text:)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(CallgrindDump(text: text))
        }
    }
}
