// Preloaded into an ordo-one/benchmark executable running under Callgrind. It stands in for the
// Linux instruction counter ordo-one/benchmark reads around each iteration, and turns the window
// between those reads into one Callgrind dump.
//
// ordo-one/benchmark opens one perf counter per CPU (syscall(SYS_perf_event_open, ...)), then:
//   enable:       ioctl(ENABLE), ioctl(RESET)
//   calibration:  read, clock read, read            (five times, after an enable, no RESET between)
//   iteration:    ioctl(RESET), read, closure, read (once per measured iteration)
//   disable:      ioctl(DISABLE)
// A closure that calls startMeasurement() adds its own RESET and read, and one that calls
// stopMeasurement() reads in place of the closing read, so its iteration is
//                 ioctl(RESET), read, setup, ioctl(RESET), read, measured part, read
// A read of the first counter opens a window when one is armed and closes the open one otherwise.
// A RESET arms a window; one arriving while a window is open discards it (its costs are zeroed),
// so a window covers only what follows the last RESET: the closure, or the part between its own
// startMeasurement() and stopMeasurement(). A window opened after a RESET is an iteration; one
// opened since an enable with no RESET is calibration, which measures the cost of the window
// itself. Each window is dumped as "iteration" or "calibration". Reads return zero, so
// ordo-one/benchmark records no instruction counts of its own.
//
// The counts don't depend on time, so a benchmark needs only a few iterations, and how many it
// runs must not depend on how busy the machine is. ordo-one/benchmark's runner keeps each
// benchmark's own wall-clock limit, measured on CLOCK_BOOTTIME, so the shim takes that clock
// over: it runs a thousand times slower than real time, so no realistic maxDuration is reached,
// and when BENCHMARK_HARNESS_ITERATIONS is set it jumps a week forward after that many measured
// iterations, so the run loop stops at its next check. A benchmark therefore measures exactly
// that many iterations, or its own maxIterations if fewer. Every other clock is left alone.
//
// Callgrind runs with --instr-atstart=no, and the shim instruments each benchmark from its
// calibration to the end of its measured iterations, so registration, setup and warmup run
// uninstrumented and several times faster. Starting instrumentation resets the simulated caches
// and branch predictor, so the first measured iteration starts cold and later ones warm.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <linux/perf_event.h>
#include <stdarg.h>
#include <stdlib.h>
#include <time.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <valgrind/callgrind.h>

#define MAX_COUNTERS 1024

static int counters[MAX_COUNTERS];
static int counter_count = 0;
static int iteration_armed = 0;
static int calibrating = 0;
static int window_open = 0;
static const char *window_name = NULL;
static long iterations_measured = 0;
static long iteration_limit = -1; // -1: not read yet; 0: no limit
static time_t boottime_offset_seconds = 0;
static int instrumented = 0;

static void count_iteration(void) {
    if (iteration_limit < 0) {
        const char *limit = getenv("BENCHMARK_HARNESS_ITERATIONS");
        iteration_limit = limit ? strtol(limit, NULL, 10) : 0;
        if (iteration_limit < 0) iteration_limit = 0;
    }
    iterations_measured += 1;
    if (iteration_limit > 0 && iterations_measured == iteration_limit) {
        boottime_offset_seconds += 7 * 24 * 60 * 60;
    }
}

#define CLOCK_SLOWDOWN 1000
#define NANOSECONDS_PER_SECOND 1000000000LL

int clock_gettime(clockid_t clock, struct timespec *time) {
    static int (*real_clock_gettime)(clockid_t, struct timespec *) = NULL;
    static long long first_boottime = -1;
    if (!real_clock_gettime) real_clock_gettime = (int (*)(clockid_t, struct timespec *))dlsym(RTLD_NEXT, "clock_gettime");
    int result = real_clock_gettime(clock, time);
    if (result != 0 || clock != CLOCK_BOOTTIME || !time) return result;
    long long now = (long long)time->tv_sec * NANOSECONDS_PER_SECOND + time->tv_nsec;
    if (first_boottime < 0) first_boottime = now;
    long long reported = first_boottime + (now - first_boottime) / CLOCK_SLOWDOWN
        + (long long)boottime_offset_seconds * NANOSECONDS_PER_SECOND;
    time->tv_sec = (time_t)(reported / NANOSECONDS_PER_SECOND);
    time->tv_nsec = (long)(reported % NANOSECONDS_PER_SECOND);
    return result;
}

static int is_counter(int fd) {
    for (int i = 0; i < counter_count; i++) {
        if (counters[i] == fd) return 1;
    }
    return 0;
}

static int is_first_counter(int fd) { return counter_count > 0 && counters[0] == fd; }

long syscall(long number, ...) {
    va_list arguments;
    va_start(arguments, number);
    long argument[6];
    for (int i = 0; i < 6; i++) argument[i] = va_arg(arguments, long);
    va_end(arguments);
    if (number == SYS_perf_event_open && counter_count < MAX_COUNTERS) {
        int fd = open("/dev/null", O_RDONLY | O_CLOEXEC);
        if (fd >= 0) counters[counter_count++] = fd;
        return fd;
    }
    static long (*real_syscall)(long, ...) = NULL;
    if (!real_syscall) real_syscall = (long (*)(long, ...))dlsym(RTLD_NEXT, "syscall");
    return real_syscall(number, argument[0], argument[1], argument[2], argument[3], argument[4], argument[5]);
}

int ioctl(int fd, unsigned long request, ...) {
    va_list arguments;
    va_start(arguments, request);
    void *argument = va_arg(arguments, void *);
    va_end(arguments);
    if (is_counter(fd)) {
        if (is_first_counter(fd)) {
            static unsigned long previous_request = 0;
            if (request == PERF_EVENT_IOC_ENABLE) {
                calibrating = 1;
                iteration_armed = 0;
                iterations_measured = 0;
                if (!instrumented) {
                    instrumented = 1;
                    CALLGRIND_START_INSTRUMENTATION;
                }
            } else if (request == PERF_EVENT_IOC_DISABLE) {
                calibrating = 0;
                iteration_armed = 0;
                if (instrumented && iterations_measured > 0) {
                    instrumented = 0;
                    CALLGRIND_STOP_INSTRUMENTATION;
                }
            } else if (request == PERF_EVENT_IOC_RESET && previous_request != PERF_EVENT_IOC_ENABLE) {
                if (window_open) {
                    // startMeasurement() inside the closure: what ran since the window opened is
                    // setup, not measurement.
                    CALLGRIND_TOGGLE_COLLECT;
                    window_open = 0;
                    CALLGRIND_ZERO_STATS;
                }
                calibrating = 0;
                iteration_armed = 1;
            }
            previous_request = request;
        }
        return 0;
    }
    static int (*real_ioctl)(int, unsigned long, ...) = NULL;
    if (!real_ioctl) real_ioctl = (int (*)(int, unsigned long, ...))dlsym(RTLD_NEXT, "ioctl");
    return real_ioctl(fd, request, argument);
}

ssize_t read(int fd, void *buffer, size_t count) {
    if (is_counter(fd)) {
        if (is_first_counter(fd)) {
            if (window_open) {
                CALLGRIND_TOGGLE_COLLECT;
                window_open = 0;
                CALLGRIND_DUMP_STATS_AT(window_name);
                if (window_name[0] == 'i') count_iteration();
            } else if (iteration_armed || calibrating) {
                window_name = iteration_armed ? "iteration" : "calibration";
                iteration_armed = 0;
                window_open = 1;
                CALLGRIND_TOGGLE_COLLECT;
            }
        }
        memset(buffer, 0, count);
        return (ssize_t)count;
    }
    static ssize_t (*real_read)(int, void *, size_t) = NULL;
    if (!real_read) real_read = (ssize_t (*)(int, void *, size_t))dlsym(RTLD_NEXT, "read");
    return real_read(fd, buffer, count);
}
