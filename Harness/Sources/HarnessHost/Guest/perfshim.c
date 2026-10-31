// Preloaded into an ordo-one/benchmark executable running under Callgrind. It stands in for the
// Linux instruction counter ordo-one/benchmark reads around each iteration, and turns the window
// between those reads into one Callgrind dump.
//
// ordo-one/benchmark opens one perf counter per CPU (syscall(SYS_perf_event_open, ...)), then:
//   enable:       ioctl(ENABLE), ioctl(RESET)
//   calibration:  read, clock read, read            (five times, after an enable, no RESET between)
//   iteration:    ioctl(RESET), read, closure, read (once per measured iteration)
//   disable:      ioctl(DISABLE)
// Every read of the first counter toggles collection. A window opened after a RESET is an
// iteration; one opened since an enable with no RESET is calibration, which measures the cost of
// the window itself. Each window is dumped as "iteration" or "calibration". Reads return zero, so
// ordo-one/benchmark records no instruction counts of its own.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <linux/perf_event.h>
#include <stdarg.h>
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
            } else if (request == PERF_EVENT_IOC_DISABLE) {
                calibrating = 0;
                iteration_armed = 0;
            } else if (request == PERF_EVENT_IOC_RESET && previous_request != PERF_EVENT_IOC_ENABLE) {
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
