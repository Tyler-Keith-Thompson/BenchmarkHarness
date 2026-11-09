# How benchmark-harness works

`benchmark-harness baseline update` builds every target of a package that uses ordo-one's
`BenchmarkPlugin`, in release, on Linux: in a virtual machine on macOS (Apple's Containerization
framework), on the host itself on Linux. It runs each benchmark executable, unchanged, under
Valgrind's Callgrind, speaking ordo-one's own runner protocol, and writes
`.benchmarkBaselines/<target>/<name>/results.json`. `--target`, `--filter` and `--skip` narrow the
run, as they do for `swift package benchmark`.

## Measurement windows

ordo-one reads a Linux instruction counter around every iteration. A small preloaded shim
(`Harness/Sources/HarnessHost/Guest/perfshim.c`) stands in for that counter: the counter reset
before an iteration and the read after it open and close one Callgrind dump, so each metric is
counted inside ordo-one's own measurement window, less the median cost of an empty window. A
benchmark that calls `startMeasurement()` and `stopMeasurement()` is counted between them.

An empty benchmark still measures a few hundred instructions, ordo-one's own per-iteration
bookkeeping, which is the same in every run and so cancels out of a comparison.

## Async benchmarks

Swift's global executor on Linux runs jobs on libdispatch's worker threads, and under Callgrind
which of them runs next depends on when the kernel wakes it, so the same async benchmark would
take different paths from run to run. A second preloaded file
(`Harness/Sources/HarnessHost/Guest/executor.c`) replaces that executor while a benchmark runs:
every job the runtime would hand to its global queues joins one queue, and its threads take
turns, one job at a time, in the order they were enqueued. A thread that blocks on a semaphore
hands its turn on, and a new thread starts when none is idle. Each thread counts only while it
holds the turn and a window is open, so a window counts the work of every task it awaits,
whichever thread runs it, and nothing of what other threads do meanwhile. Main-actor jobs still
run on the main thread, and are counted there.

An async benchmark therefore counts the same instructions in every run, as a synchronous one
does. The exceptions:

- Work submitted to dispatch queues or threads directly isn't counted.
- Main-actor jobs vary by a few hundred instructions, from the handoff to the main thread.
- A job that waits for another job by spinning or on a condition variable never finishes, since
  that job can't run until it does. A semaphore wait (`DispatchSemaphore`) is fine.

## Keeping simulation affordable

A measured iteration runs roughly fifty times slower under Callgrind than natively. The tool keeps
that cost to what is measured:

- Each benchmark measures exactly three iterations (`--iterations`), or fewer when its own
  `maxIterations` is lower, whatever its time limit and however busy the machine is. Its own
  warmup iterations run first.
- Callgrind instruments each benchmark only from the start of its measurement to its last
  iteration, so registration, setup and warmup run several times faster.
- Each benchmark runs in a process of its own, so its counts don't depend on which benchmarks ran
  before it or were filtered out, and benchmarks are measured side by side (`--jobs`, by default
  the virtual machine's `--cpus`, or the host's processors on Linux), since one Callgrind process
  uses one processor.

The value recorded is the median over the measured iterations. The simulated caches and branch
predictor start cold at the first measured iteration and stay warm after it, so with three
iterations the median is a warm one.

## Counted metrics

A benchmark's own metrics that don't depend on time are recorded beside the simulated ones:
allocation, free and leak counts (`mallocCountTotal`, `memoryLeaked`, …), Swift object, retain and
release counts (`objectAllocCount`, `retainCount`, …) and custom metrics. They are measured in a
second run of the benchmark, without Valgrind, over the same number of iterations, so `baseline
compare` and `check` see them as `swift package benchmark` records them. Time, memory and
system-call metrics are left out.

## Runs side by side

Several runs, from different packages or checkouts, can run at once. Runs on the same checkout
take turns, under a lock held from staging to writing the baseline, since they share its build
products; a waiting run names the process it waits for.

A run stops on SIGINT, SIGTERM or SIGHUP, and when the process that started it exits, ending its
benchmark processes and virtual machine and releasing the checkout. A timeout wrapper around a
tool that doesn't pass signals on (such as `just`) therefore stops the run too.

## The virtual machine

The guest boots the Swift image pinned in `GuestMachine.image`, with a pinned kernel, and the
checkout shared read-only. It has no network interface: package resolution inside it goes through
an HTTPS `CONNECT` proxy that listens on a Unix socket readable only by the current user and admits
port 443 alone.

## Valgrind

The first run downloads Valgrind 3.28.0's source, verifies its digest, applies a local patch and
builds it, then caches the installation. The patch fixes two Valgrind bugs that Swift executables
hit; `Harness/NOTES.md` records them, with other third-party behaviour the tool works around.

## Comparing across machines

Counts depend on the processor architecture, the Swift toolchain and the Valgrind build, so compare
baselines recorded on the same kind of machine. On aarch64 with the virtual machine's Swift image,
a Linux host's instruction counts match the virtual machine's; cache misses and mispredicted
branches differ by up to a few percent on small counts, and allocation counts by a few. Recording
both baselines of a comparison on the same host avoids depending on any of that.
