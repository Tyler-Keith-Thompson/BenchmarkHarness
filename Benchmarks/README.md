# Benchmarks

A separate SwiftPM package built on [ordo-one/benchmark](https://github.com/ordo-one/benchmark),
so the library and its tests never depend on the benchmark framework. Bazel ignores this directory
(`.bazelignore`).

Requires `brew install jemalloc`.

| Command | Does |
|---|---|
| `just bench` | Run every benchmark (`--target X` for one) |
| `just bench-baseline` | Save the current results as the `main` baseline |
| `just bench-compare` | Compare the current results against `main` |
| `just bench-simulated [--target X]` | Record simulated counts, in a Linux virtual machine, as the `simulated` baseline |
| `just bench-simulated-compare [--target X]` | Record simulated counts as `simulated-current` and compare them against `simulated` |

Each module's benchmarks live in `Benchmarks/<Module>Benchmarks/` and start with a `BASELINE`
entry: the hand-written form the library must keep pace with. Only the `main` and `simulated`
baselines are committed; other names are local before/after comparisons.

`Benchmarks/MeasurementWindowBenchmarks/` holds fixtures for `benchmark-harness` rather than
benchmarks of a module: three benchmarks measure the same thousand calls, whole and between their
own `startMeasurement()` and `stopMeasurement()` after costly setup, so their simulated instruction
counts must stay within a few hundred of each other.

`Benchmarks/LongIterationBenchmarks/` is another fixture: one benchmark whose iteration is a naive
scan of a thousand patterns at every offset of a 10⁵-byte text, about 1.3 billion instructions
taken through tight loops in a single call. Under Callgrind it must finish in a few minutes rather
than grow Valgrind's memory until the guest kills it.

`Benchmarks/ThreadBenchmarks/` is another fixture: a thousand and ten thousand calls on a detached
task, a thousand on an actor between hops and a thousand on the main actor. Their counts must grow
with the number of calls, since the work runs on another thread than the measurement's, and every
sample but the main actor's must repeat exactly between recordings.

`just bench-simulated` counts instructions, cache misses and mispredicted branches under Callgrind
instead of timing, so its baselines don't move when the machine is busy. Compare against one as
against any other: `swift package benchmark baseline compare main`.
