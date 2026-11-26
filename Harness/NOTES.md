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

## Valgrind 3.28.0: Callgrind's skipped PLT stubs on arm64 (BH-23)

With `--skip-plt=yes`, Callgrind's default, a PLT stub is a skipped function: its costs are charged
to the calling function rather than a function of its own. That default broke two things.

**A call-stack leak.** A call into a stub pushes a call-stack entry, and the stub's `br x17` into
another object is treated as a call too (`bbcc.c` emulates a jump across objects as one), pushing
the target's entry. In `--ct-verbose2` traces of an arm64 Swift benchmark (ECS-27), the target's
return pops only its own entry and leaves the stub's behind, so the caller's own return pops that
stale entry instead of its frame. Each call made through a stub leaks one entry; they pile up until
the stack pointer rises past the loop's frame and Callgrind unwinds them. `callgrind_control -b`
showed about 350,000 repeated frames in one loop of ECS's `WorldBenchmarks`, and those loops ran
about 100× slower under Callgrind: "read a resource and a component of a world held by a final
class" (470 million instructions) took over an hour per iteration, past the 1000× slowed clock's
headroom for its 3 s `maxDuration`, so it recorded one cold iteration.

**Costs that survive a zero.** While collection is on, a skipped function's costs also go to the
caller's `skipped` array (`main.c`, the cache simulation's log functions; `bbcc.c` without it).
`CALLGRIND_ZERO_STATS` resets each BBCC's own costs but not that array (`zero_bbcc`), and the next
dump adds it in (`dump.c`). A benchmark that calls `startMeasurement()` runs its setup inside a
window that the shim then discards with a zero, so the PLT stubs its setup ran through (every call
into another library, `swift_retain` among them) were counted in its iteration. Benchmarks without
the explicit calls collect nothing between windows and were unaffected.

`run-benchmarks.sh` passes `--skip-plt=no`, so each stub is a function with a call-stack entry and
costs of its own: the stub's return and the caller's both match, and a zero clears everything. A
Valgrind patch was not needed; the option is upstream's own, and its other effect, stubs appearing
as functions in the call graph, is in nothing the harness reads. Not reported upstream.

Its effect, measured with the harness before and after on the same sources, collection under
`--toggle-collect='__swift_run_job(*'` included:

- This repository's benchmarks: every instruction count is identical except the two
  `MeasurementWindowBenchmarks` that call `startMeasurement()`, which drop by 194 each (9,615 to
  9,421 and 9,685 to 9,491), 3 and 73 more than the whole closure's 9,418. Their level-1 misses
  drop from 38 and 40 to 27; every other miss and mispredicted-branch count moved within the noise
  "What repeats exactly" describes. Malloc counts, from the native run, are unchanged.
- ECS's `WorldBenchmarks` at a50d8da (46 benchmarks; the two slowed ones can't finish under the old
  harness): the 4 that don't call `startMeasurement()` count exactly what they did. The 42 that call
  it after building a world drop by their setup's stub instructions, most by 194 to 16,000, those
  with large setups by much more: "look up a thousand indexed values, a thousand entities each" 25,433,726 to
  1,433,480, "update one type reading one, grouped with it" 136,026,568 to 84,016,826, "list every
  entity sorted by the key of an ordered index" 33,560,045 to 16,493,312, "insert an indexed
  component into every entity" 2.504 to 2.348 billion. Retain counts are identical, and malloc and
  release counts differ by at most 2, from the native run.

The whole target now records three iterations of every benchmark in 33 minutes, the final-class
read in 1 min 18 s. Simulated baselines of benchmarks that call `startMeasurement()` must be
re-recorded.

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

## Where builds go: a case-sensitive disk per checkout, a directory per package (BH-26)

SwiftPM's scratch directories live in the cache's `guest/builds/`. On macOS that is
`<checkout digest>.ext4`, a sparse 256 GiB ext4 image formatted by Containerization's
`EXT4.Formatter` (journalled), which the guest mounts at `/builds` as a block device. On Linux it
is the directory `<checkout digest>/`. Inside it, each package of the checkout has its own scratch
directory, keyed by the package's path relative to the checkout (`scratchPath(builds:package:)`).

Scratch directories used to sit on the shared volume, one per checkout. On a Mac that share is the
host's APFS, case-insensitive by default, and every `--package-path` under one checkout built
into the same directory. Traffluent's CBOR comparison packages showed the result: one built
valpackett/SwiftCBOR (module `SwiftCBOR`), and a later one using nnabeyang/swift-cbor (module
`SwiftCbor`) then failed every time with `no such module 'SwiftCbor'`, because the share merged the
two modules' files. A package depending on both failed the same way even in a fresh scratch.
Reproduced with harness 0.0.11; all three record with the disk.

Why a disk image rather than the guest's own root file system, which is case-sensitive too: the
container's root file system is deleted at shutdown, so every run would rebuild every dependency.
The image persists, so a second run of an unchanged package plans and links in about a second.
It takes host disk space only as the guest writes to it, and only one guest mounts it at a time,
under the checkout lock. It never gives space back when files inside it are deleted; eviction
(below) deletes whole images, and the next run on that checkout formats a new one.
A separate scratch per package costs each package one cold build of its dependencies, but two
packages of a checkout never share a module's build products.

## Keeping the cache bounded (BH-27)

The cache measured 98 GB on the owner's Mac, and nothing deleted any of it: 54 GB of container
root file systems (`store/containers/benchmark-harness-<pid>`, 4 GiB each) left by runs killed
before they shut their guest down, 40 GB of scratch directories in `guest/scratch` from before the
disk images, and an image per checkout, while worktrees come and go.

Each run now evicts (`HarnessCache.evict(limitInBytes:)`) after taking its own checkout lock and
before formatting its image:

- Beside each checkout's builds, `guest/builds/<checkout>.json` records the checkout's path; a run
  rewrites it, so its modification time is the checkout's last use. Builds whose checkout no
  longer exists, or that have no record (made before it), are deleted.
- Then, while the remaining builds (the image on macOS; `guest/builds/<checkout>` and
  `guest/work/<checkout>` on Linux) take more than the limit, the least recently used checkout's
  are deleted. The limit is 50 GiB, `--cache-limit <GiB>` on the command line,
  `cacheLimitInBytes` on `SimulatedBaselineRecorder`. Sizes count the blocks allocated, so a
  sparse image counts what has been written to it.
- Every directory in `guest/scratch` is deleted, and the containers and day-old dumps of runs whose
  process is no longer running (a reused process identifier keeps its leftovers until that process
  ends too).

A checkout's builds are deleted only while holding its checkout lock, taken without waiting
(`CheckoutLock(attempting:)`); one held by a run, this run's own included, is skipped. The lock
files themselves stay: deleting one would let a run waiting on the old file and a run opening a
new one both hold the lock. Foundation's `Process` shares even close-on-exec descriptors with a
child until it executes its program, so a lock released a moment ago can read as held; the
checkout is then skipped until a later run. Downloads, the kernel, the Valgrind archives and the
guest files are small and kept.

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
After: 9,415, 9,607 and 9,678, each with identical samples; with `--skip-plt=no` (BH-23), 9,418,
9,421 and 9,491. The explicit calls' own path costs 3 to 73 instructions more than ordo-one's
implicit start and stop; the calibration window measures the implicit path, so that difference
stays in, constant per benchmark.
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

## Hoy as the guest's virtual machine (BH-19)

Hoy (hoy.cua.ai, from Cua) is a virtual machine monitor of its own on Hypervisor.framework, not on
Virtualization.framework or QEMU, with its own devices, snapshots and forks. It is free to use,
commercial use included, under the Hoy EULA; it is closed source, and its only interface is the
`hoy` command-line tool (`create`, `start`, `exec`, `ssh`, `vnc`), with no API or Swift package. It
needs an Apple silicon Mac on macOS 26 or later.

It runs only macOS guests (macOS 26 and 27, from Apple's restore images), so it cannot run the
Linux guest at all, and macOS's license allows two macOS virtual machines at once per Mac, which
rules out concurrent recordings. Each virtual machine gets its own network address and is reached
over ssh; its documentation describes no way to run one without a guest network interface (N4).
Its published speed-up is in boot (5.3 s against 6.6 s on an M4 Pro), save and restore, none of
which a recording spends much time on next to Valgrind. `GuestMachine` stays on
apple/containerization; Hoy was not measured, since it cannot boot the guest. Cua's Lume does run
Linux guests, but on Virtualization.framework, the framework containerization already uses.
