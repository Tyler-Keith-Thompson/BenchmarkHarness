# Harness notes

## Valgrind 3.28.0: `rt_sigsuspend` writes into a read-only signal mask

`PRE(sys_rt_sigsuspend)` in `coregrind/m_syswrap/syswrap-linux.c` removes `VG_SIGVGKILL` from the
client's mask in place (`VG_(sigdelset)` on `ARG1`). libdispatch passes a mask that lives in
read-only memory, so any Swift executable that parks a dispatch worker under Valgrind dies with
SIGSEGV in `vgPlain_sigdelset`. Also seen on 3.22.

`Sources/HarnessHost/Guest/valgrind-rt_sigsuspend.patch` copies the mask into per-thread storage
and points the syscall at the copy. `provision.sh` applies it before building Valgrind.

Not reported upstream.

## Inlined `Benchmark.run()` and Callgrind call-edge costs

In release builds `Benchmark.run()` is inlined, so no symbol marks an iteration, and Callgrind's
inclusive call-edge costs are wrong for Swift because tail calls confuse its call tracking. The
harness therefore dumps program-wide totals per window, with the window marked by ordo-one's own
counter reads (`perfshim.c`).

## ordo-one/benchmark's runner keeps a benchmark's own iteration limits

In 1.38.0 the runner takes only `configuration.metrics` from a `run` request
(`BenchmarkRunner.swift`, `case .run`); `maxIterations`, `maxDuration` and `warmupIterations` in
the request are ignored, and no option or environment variable sets them. A benchmark's loop
stops at `maxIterations` or once `maxDuration` has passed on `BenchmarkClock`, which on Linux is
`clock_gettime(CLOCK_BOOTTIME)`. Under Callgrind that wall-clock limit would make the iteration
count depend on host load, so `perfshim.c` runs `CLOCK_BOOTTIME` a thousand times slower and jumps
it a week forward after the requested number of measured iterations.

## Starting instrumentation resets the simulated caches

`CALLGRIND_START_INSTRUMENTATION` starts the cache and branch simulation cold. Toggling it around
each measured window made every iteration cold, so small benchmarks counted hundreds of
last-level misses that a warm run doesn't have. The shim instead instruments from a benchmark's
calibration to its last measured iteration: only the first iteration is cold, and the median of
three discards it.

## What repeats exactly

Across repeated runs of the same build, instruction counts repeat exactly. Level-1 miss medians
move by up to about 1.5% and mispredicted branches by about 0.1%, more when several Callgrind
processes run at once. Disabling the guest's address-space randomization
(`setarch --addr-no-randomize`) changed nothing; the likely source is when the Swift runtime's
background threads are scheduled under Valgrind, which depends on real time and touches the
simulated caches and branch predictor between iterations.

## One process per benchmark

Benchmarks that share a process leave allocator and runtime state for the ones after them: ECS's
`spawn three components` counted 1,695,547,391 instructions alone and 1,695,192,953 after the
benchmarks before it. Each benchmark is therefore measured in a process of its own, so a filtered
run counts what a full run does, and one target's benchmarks run side by side. Each process
registers every benchmark of its target again, uninstrumented.
