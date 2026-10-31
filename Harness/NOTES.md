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
