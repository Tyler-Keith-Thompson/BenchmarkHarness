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
| `just bench-simulated [name]` | Record simulated counts as a baseline (default `main`) in a Linux virtual machine |

Each module's benchmarks live in `Benchmarks/<Module>Benchmarks/` and start with a `BASELINE`
entry: the hand-written form the library must keep pace with. Only the `main` baseline is
committed; other names are local before/after comparisons.

`just bench-simulated` counts instructions, cache misses and mispredicted branches under Callgrind
instead of timing, so its baselines don't move when the machine is busy. Compare against one as
against any other: `swift package benchmark baseline compare main`.
