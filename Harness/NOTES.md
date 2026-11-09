# Harness notes

## Valgrind 3.28.0: `rt_sigsuspend` writes into a read-only signal mask

`PRE(sys_rt_sigsuspend)` in `coregrind/m_syswrap/syswrap-linux.c` removes `VG_SIGVGKILL` from the
client's mask in place (`VG_(sigdelset)` on `ARG1`). libdispatch passes a mask that lives in
read-only memory, so any Swift executable that parks a dispatch worker under Valgrind dies with
SIGSEGV in `vgPlain_sigdelset`. Also seen on 3.22.

The first hunk of `Sources/HarnessHost/Guest/valgrind.patch` copies the mask into per-thread
storage and points the syscall at the copy. `provision.sh` applies the patch before building
Valgrind.

Not reported upstream.

## Valgrind 3.28.0: arm64 `B` is decoded as a call

`dis_ARM64_branch_etc` in `VEX/priv/guest_arm64_toIR.c` ends every unconditional immediate branch
with `Ijk_Call`, `B` as well as `BL`. Callgrind pushes a call-stack frame for each call and pops
frames only when the stack pointer rises past them or a return matches, so every `B` a function
takes adds a frame that stays until the function returns. A function whose loops take ~10⁸
branches in one call (a naive scan over a 10⁵-byte text) grows Callgrind's call stack by gigabytes
until the kernel's OOM killer ends Valgrind; its call graph shows the function recursing into
itself. Instruction, cache and branch counts are unaffected.

The second hunk of `valgrind.patch` marks `B` as `Ijk_Boring`. Not reported upstream.

## Containerization: an exec'd process's standard output can stay open after it exits

With apple/containerization 0.54.0, a process started with `LinuxContainer.exec` whose standard
output goes to a custom `Writer` exits (`wait()` returns its status), yet the writer's `close()`
is not called; seen with a benchmark executable that calls `exit(3)` while its standard input is
still open. A reader of that output waits forever. `GuestMachine.run` therefore finishes its output
stream itself once the process has exited.

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

## Explicit startMeasurement() and stopMeasurement()

A closure that calls `startMeasurement()` resets and reads the counters again, after its setup, and
one that calls `stopMeasurement()` reads them in place of ordo-one's closing read, so an iteration
is `RESET, read, setup, RESET, read, measured part, read`. The shim toggled a window on every read,
so it dumped the setup as an iteration and fell out of phase: ECS's ordered-index benchmarks
recorded samples from 3 million to 43 billion instructions within one benchmark. A RESET now
discards an open window (`CALLGRIND_ZERO_STATS` after collection stops), so a window covers only
what follows the last RESET.

`Benchmarks/MeasurementWindowBenchmarks` measures a thousand calls three ways. Before the fix:
9,415 (whole closure), 9,418 to 9,053,531 (after a million calls of setup and
`startMeasurement()`), 9,489 to 9,125,701 (between `startMeasurement()` and `stopMeasurement()`).
After: 9,415, 9,607 and 9,678, each with identical samples. The explicit calls' own path costs
about 200 to 260 instructions more than ordo-one's implicit start and stop; the calibration
window measures the implicit path, so that difference stays in, constant per benchmark.
Benchmarks without explicit calls count what they did before, exactly.

## Async benchmarks: per-thread collection and libdispatch's scheduling (BH-17)

Callgrind's collection state is per thread (`exec_state.collect`), and `--collect-atstart=no`
starts every new thread with it off. The shim used to open and close each window with
`CALLGRIND_TOGGLE_COLLECT` on the thread that read the counter, so a window counted only that
thread: work an async benchmark awaited on another thread of the pool went uncounted, and a window
whose closing read ran on another thread than its opening one left collection on for one thread and
flipped it on another. `ThreadBenchmarks` (a thousand and ten thousand calls on a detached task)
recorded instruction medians of 82,367, 17,519 and 121,279 for a thousand calls over three
recordings, and 121,151 to 123,455 for ten thousand: the calls weren't counted. Afluent's
`SingleValueSubject: send then execute` recorded 21,740 to 22.6 million, `SerialTaskQueue: enqueue`
3.79 to 7.66 million; its async BASELINE entries moved 8 to 11%. Synchronous benchmarks repeated
exactly, and malloc counts (from the native run) moved by up to 8%.

Counting every thread (`--collect-atstart=yes`, zeroing and dumping at the window's edges) made
the counts scale with the work but not repeat: libdispatch's workers take turns on Valgrind's lock
in the order the kernel wakes them, so a job is found waiting or a parked worker is woken
differently each run (0.9 to 6.6% between recordings). `--fair-sched=yes` narrowed it (0 to 6.6%);
`LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` changed nothing, since swift-corelibs-libdispatch has no
cooperative pool.

`Guest/executor.c` now replaces the global executor. Swift 6.4's executor submits each job with
`dispatch_async_f(queue, job, __swift_run_job)` to concurrent queues it creates, and only some
paths consult `swift_task_enqueueGlobal_hook` (a hooked run still sent 8 jobs per run of the actor
fixture straight to libdispatch), so the file records the queues `libswift_Concurrency.so` creates
and takes every job submitted to them; delayed jobs come through the delay and deadline hooks.
Jobs run one at a time from one queue, and a thread that blocks in `sem_wait` hands the turn on
(ordo-one's runner blocks on a `DispatchSemaphore` while its async benchmark runs). A thread
collects only while it holds the turn and a window is open, so the parking of dispatch workers and
the tail of a thread going into `sem_wait` stay out of the counts, and synchronous benchmarks
count exactly what they did before (`MeasurementWindowBenchmarks`: 9,418, identical samples).
Main-actor jobs stay on the main queue; `--toggle-collect='__swift_run_job(*'` counts them.

Two details mattered. `CALLGRIND_START_INSTRUMENTATION` resets every thread's collection to
`--collect-atstart` (`set_instrument_state` runs `unwind_thread`, then `init_exec_state`, on all
threads), so the executor's record of what each thread collects is reset with it; the shim changes
instrumentation only with no window open. And the lookup of a queue compares every slot: the
runtime creates a queue per priority when it first needs it, in an order that varies, and an early
exit cost 16 instructions more or less depending on it.

After, over three recordings: `ThreadBenchmarks` records 15,495 and 96,494 (identical samples) for
a thousand and ten thousand calls on a detached task, and 16,858 on an actor between hops; the main
actor's 12,767 to 12,991, from the handoff to the main thread. Afluent's twenty instruction
medians agree to within 12 instructions (`SingleValueSubject: send then execute` 25,156,833 to
25,156,836; `SerialTaskQueue: enqueue` 11,511,942 each time), one BASELINE to within 174, and every
malloc count is identical. Level-1 miss counts still move by up to 10% on Afluent's small ones.
Baselines of async benchmarks recorded before must be re-recorded; synchronous ones are unchanged.
