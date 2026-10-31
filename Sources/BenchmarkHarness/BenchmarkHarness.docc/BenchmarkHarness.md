# ``BenchmarkHarness``

Reads Callgrind's profile dumps and writes them as ordo-one/benchmark baselines, so benchmark
counts come from simulated hardware rather than a clock.

## Overview

``Callgrind`` parses the event totals of each dump Callgrind writes. ``SimulatedMetrics`` derives
instruction, cache-miss, branch-misprediction and cycle-estimate metrics from those totals, less the
cost of measuring. ``BenchmarkBaselines`` encodes the results in the format
`swift package benchmark baseline compare` reads, and ``BenchmarkCommands`` speaks the protocol
ordo-one/benchmark's runner uses to list and run a benchmark executable's benchmarks. Every public
type is a value type; plain spellings trap on bad input and `checked:` spellings throw.

`import BenchmarkHarness` imports every module. Each module also has its own documentation and can be
imported on its own.

```swift
import BenchmarkHarness

let iterations = [
    CallgrindDump(text: "events: Ir I1mr D1mr D1mw ILmr DLmr DLmw Bcm Bim\ntotals: 4100 2 9 3 0 1 0 12\n"),
]
let overhead = [
    CallgrindDump(text: "events: Ir I1mr D1mr D1mw ILmr DLmr DLmw Bcm Bim\ntotals: 100\n"),
]
let result = BenchmarkResult(metric: .instructions, iterations: iterations, overhead: overhead, warmupIterations: 0)
print(result.statistics.valueAtPercentile(50))  // 4000
```

## Topics

### Modules

- ``Callgrind``
- ``SimulatedMetrics``
- ``BenchmarkBaselines``
- ``BenchmarkCommands``
