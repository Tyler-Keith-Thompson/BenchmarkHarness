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

## Allocation and reference counts come from a second, native run

ordo-one/benchmark counts allocations through its malloc interposer and, on Linux with Swift 6.3,
retains and releases through `libSwiftRuntimeInterposerSwift.so`, which its plugin puts in
`LD_PRELOAD` from beside the executable. Without the preload the runtime interposer counts
nothing, the `- 1` ordo-one subtracts from each retain and release delta makes it negative, and
`Statistics.add` drops negative measurements, so the result goes missing rather than reading zero.
`run-benchmarks.sh` preloads both in its native mode, as the plugin does.

Requesting these metrics also installs their hooks, which add instructions to every window, so the
simulated pass requests only the simulated metrics and a second process, without Valgrind and with
the same shim and iteration count, measures the counted ones. On ECS's `spawn three components`
the simulated counts are unchanged (1,695,460,606 instructions) and the native pass reports 302
allocations, 4 retains and 357 releases per measurement.

## A Linux host against the virtual machine

On Linux the tool runs the guest scripts on the host (`HostMachine`), with Valgrind and the shim
under the cache instead of `/opt`. Recorded in the guest's Swift image under Docker (OrbStack's
kernel 7.0.11, aarch64) and compared with the virtual machine (kernel 6.12.28) on this repository's
`Benchmarks/`:

- Three instruction medians match exactly (69,012; 4,325,375; 5,369,855); the fourth differs by
  61 of 3.2 million (3,187,576 against 3,187,515). Each run's minimum is the same.
- An empty measurement window costs 2,352 instructions on that kernel against 424 in the virtual
  machine: ordo-one's clock and counter reads cost what the kernel's vDSO and system calls cost.
  The calibration window is subtracted, so per-iteration counts don't carry it.
- Level-1 misses and mispredicted branches differ by up to about 4% on counts in the hundreds,
  last-level misses by at most 3.
- Allocation counts, measured natively, differ by up to 2 (20 against 22).

Docker on macOS shares host directories case-insensitively, where Valgrind's documentation install
fails (`FAQ.html` against `faq.html`); provisioning installs into a staging root and the cache in
such tests belongs on a Linux volume.

## SwiftPM's cached build plan and added files

The scratch directory persists between runs, and staging keeps the checkout's modification times
so builds stay incremental. GrafluentCollections hit a build that reused a cached
`description.json` from before `Treap.swift` was added, and failed with `cannot find type 'Treap'
in scope` though the staged copy had the file. A one-file addition in this repository didn't
reproduce it, so the trigger is not pinned down. `stage.sh` now records the staged file names per
scratch directory and deletes SwiftPM's cached plans (`*.yaml`, `description.json`) when they
change, so a build after an added, removed or renamed file always plans again; compiled products
are kept.
