// Preloaded with perfshim.c: Swift concurrency's global executor, replaced by one that runs one job
// at a time, in the order they were enqueued.
//
// Swift's default global executor on Linux runs jobs on libdispatch's worker threads. Under
// Callgrind those threads take turns on Valgrind's lock, and which one runs next depends on when
// the kernel wakes it, so the same async benchmark runs different paths (a job found already
// waiting, or a worker parked and woken) and counts different instructions from run to run.
//
// This executor takes the jobs the runtime submits to its global queues (below), and the delayed
// ones through Swift's documented hooks, and keeps them in one queue. Its threads hold a single
// turn between them: a thread runs a job only while it holds the turn, and runs the next queued
// job itself when it finishes one, so a window that awaits other tasks runs them on one thread,
// in a fixed order, without any thread waking another. A thread that blocks on a semaphore (DispatchSemaphore,
// ordo-one/benchmark's runner waiting for an async benchmark) gives up the turn first and takes it
// back after; when no thread is idle, a new one starts, so blocking never stalls the queue.
//
// A job that waits for another job by any other means (spinning on an atomic, a condition
// variable) would wait forever, since that job can't run until it finishes. Jobs on the main actor
// and work submitted to dispatch queues directly keep their own threads; only the main actor's
// are counted.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <semaphore.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <valgrind/callgrind.h>

typedef struct Job Job;

typedef void (*delay_original)(unsigned long long, Job *) __attribute__((swiftcall));
typedef void (*deadline_original)(long long, long long, long long, long long, int, Job *) __attribute__((swiftcall));

// SerialExecutorRef::generic() is two zero words, passed in two registers.
typedef void (*job_run)(Job *, void *, uintptr_t) __attribute__((swiftcall));

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t work = PTHREAD_COND_INITIALIZER;
static pthread_cond_t turn_free = PTHREAD_COND_INITIALIZER;
static job_run run_job;

// The queue: a ring of job pointers in memory from mmap, so growing it allocates nothing that
// ordo-one/benchmark's malloc counter sees.
static Job **ring = NULL;
static size_t capacity = 0, head = 0, count = 0;
static int turn_taken = 0;
static int idle_threads = 0;
static __thread int holds_turn = 0;

// Callgrind runs with --collect-atstart=no, and its collection state is per thread. A thread
// collects while a measurement window is open and it holds the turn, so a window counts the jobs
// that ran in it and none of what other threads do meanwhile (a dispatch worker parking, a
// blocked thread on its way into the kernel), whose timing is real time's. perfshim.c opens and
// closes windows through executor_window(). Main-actor jobs run on the main queue as before;
// run-benchmarks.sh has Callgrind collect inside the runtime's function that runs each one.
static __thread int collecting = 0;
static int window_open = 0;

static void collect(int on) {
    if (collecting != on) {
        collecting = on;
        CALLGRIND_TOGGLE_COLLECT;
    }
}

static void collect_if_measuring(void) {
    collect(holds_turn && __atomic_load_n(&window_open, __ATOMIC_ACQUIRE));
}

// The thread that opens or closes a window holds the turn, or this isn't a Swift program and it
// is the only thread measured.
void executor_window(int open) {
    __atomic_store_n(&window_open, open, __ATOMIC_RELEASE);
    collect(open && (holds_turn || !run_job));
}

// Starting or stopping instrumentation resets every thread's collection to --collect-atstart's
// (Callgrind's set_instrument_state); perfshim.c does it with no window open, so no thread is
// collecting afterwards.
void executor_instrumentation_changed(void) { collecting = 0; }

static void *checked_mmap(size_t bytes) {
    void *memory = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (memory == MAP_FAILED) abort();
    return memory;
}

static void push(Job *job) {
    if (count == capacity) {
        size_t grown = capacity ? capacity * 2 : 4096;
        Job **larger = checked_mmap(grown * sizeof(Job *));
        for (size_t i = 0; i < count; i++) larger[i] = ring[(head + i) % capacity];
        if (ring) munmap(ring, capacity * sizeof(Job *));
        ring = larger;
        capacity = grown;
        head = 0;
    }
    ring[(head + count) % capacity] = job;
    count += 1;
}

static Job *pop(void) {
    Job *job = ring[head];
    head = (head + 1) % capacity;
    count -= 1;
    return job;
}

static void *worker(void *unused);

// Called with the lock held: a queued job runs as soon as the turn is free.
static void wake_or_start_thread(void) {
    if (count == 0 || turn_taken) return;
    if (idle_threads > 0) {
        pthread_cond_signal(&work);
        return;
    }
    pthread_t thread;
    pthread_attr_t attributes;
    pthread_attr_init(&attributes);
    pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
    if (pthread_create(&thread, &attributes, worker, NULL) != 0) abort();
    pthread_attr_destroy(&attributes);
    idle_threads += 1; // Counted from its start, so the next enqueue doesn't start another.
}

static void *worker(void *unused) {
    (void)unused;
    pthread_mutex_lock(&lock);
    for (;;) {
        while (count == 0 || turn_taken) pthread_cond_wait(&work, &lock);
        idle_threads -= 1;
        turn_taken = 1;
        holds_turn = 1;
        collect_if_measuring();
        while (count > 0) {
            Job *job = pop();
            pthread_mutex_unlock(&lock);
            run_job(job, NULL, 0);
            pthread_mutex_lock(&lock);
        }
        collect(0);
        holds_turn = 0;
        turn_taken = 0;
        idle_threads += 1;
        pthread_cond_signal(&turn_free);
    }
    return NULL;
}

static void enqueue(Job *job) {
    pthread_mutex_lock(&lock);
    push(job);
    wake_or_start_thread();
    pthread_mutex_unlock(&lock);
}

// The runtime's global executor submits each job to one of the concurrent queues it creates, as
// dispatch_async_f(queue, job, function), whichever path enqueued it (its hook covers only some).
// The queues it creates are recorded, and a job it submits to one of them joins this queue instead.
// Its other queue work (the main queue, actors on a dispatch queue) goes to libdispatch unchanged.
#define MAX_RUNTIME_QUEUES 64
static void *runtime_queues[MAX_RUNTIME_QUEUES];
static int runtime_queue_count = 0;
static void (*runtime_job_function)(void *) = NULL;

static int in_runtime(void *address) {
    Dl_info info;
    return dladdr(address, &info) && info.dli_fname && strstr(info.dli_fname, "libswift_Concurrency.so");
}

void *dispatch_queue_create(const char *label, void *attributes) {
    static void *(*real_dispatch_queue_create)(const char *, void *) = NULL;
    if (!real_dispatch_queue_create) real_dispatch_queue_create = (void *(*)(const char *, void *))dlsym(RTLD_NEXT, "dispatch_queue_create");
    void *queue = real_dispatch_queue_create(label, attributes);
    if (run_job && in_runtime(__builtin_return_address(0))) {
        pthread_mutex_lock(&lock);
        if (runtime_queue_count < MAX_RUNTIME_QUEUES) runtime_queues[runtime_queue_count++] = queue;
        pthread_mutex_unlock(&lock);
    }
    return queue;
}

// Every slot is compared, so the check costs the same whichever slot holds the queue: the runtime
// creates its queues when it first needs each priority, in an order that can vary between runs.
static int is_runtime_queue(void *queue) {
    pthread_mutex_lock(&lock);
    int found = 0;
    for (int i = 0; i < MAX_RUNTIME_QUEUES; i++) found |= runtime_queues[i] == queue;
    pthread_mutex_unlock(&lock);
    return found;
}

void dispatch_async_f(void *queue, void *context, void (*function)(void *)) {
    static void (*real_dispatch_async_f)(void *, void *, void (*)(void *)) = NULL;
    if (!real_dispatch_async_f) real_dispatch_async_f = (void (*)(void *, void *, void (*)(void *)))dlsym(RTLD_NEXT, "dispatch_async_f");
    if (run_job && is_runtime_queue(queue)) {
        if (!runtime_job_function && in_runtime((void *)function)) runtime_job_function = function;
        if (function == runtime_job_function) {
            enqueue(context);
            return;
        }
    }
    real_dispatch_async_f(queue, context, function);
}

// Delayed jobs wait on a thread of their own until their time, then join the queue.
typedef struct {
    struct timespec deadline;
    clockid_t clock;
    Job *job;
} Delayed;

static void *delayed(void *argument) {
    Delayed *delay = argument;
    while (clock_nanosleep(delay->clock, TIMER_ABSTIME, &delay->deadline, NULL) == EINTR) {}
    Job *job = delay->job;
    munmap(delay, sizeof(Delayed));
    enqueue(job);
    return NULL;
}

static void enqueue_at(clockid_t clock, struct timespec deadline, Job *job) {
    Delayed *delay = checked_mmap(sizeof(Delayed));
    delay->deadline = deadline;
    delay->clock = clock;
    delay->job = job;
    pthread_t thread;
    pthread_attr_t attributes;
    pthread_attr_init(&attributes);
    pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
    if (pthread_create(&thread, &attributes, delayed, delay) != 0) abort();
    pthread_attr_destroy(&attributes);
}

__attribute__((swiftcall)) static void enqueue_global_with_delay(unsigned long long nanoseconds, Job *job, delay_original original) {
    (void)original;
    struct timespec deadline;
    clock_gettime(CLOCK_MONOTONIC, &deadline);
    unsigned long long total = (unsigned long long)deadline.tv_nsec + nanoseconds % 1000000000ULL;
    deadline.tv_sec += (time_t)(nanoseconds / 1000000000ULL + total / 1000000000ULL);
    deadline.tv_nsec = (long)(total % 1000000000ULL);
    enqueue_at(CLOCK_MONOTONIC, deadline, job);
}

// The deadline is on the clock the benchmark reads, which perfshim.c slows and moves forward, so
// what's left of it is measured on that clock and then waited for in real time.
__attribute__((swiftcall)) static void enqueue_global_with_deadline(long long seconds, long long nanoseconds, long long tolerance_seconds,
                                                                   long long tolerance_nanoseconds, int clock, Job *job, deadline_original original) {
    (void)original;
    (void)tolerance_seconds;
    (void)tolerance_nanoseconds;
    // The runtime's clock identifiers: 1 is ContinuousClock (CLOCK_BOOTTIME on Linux), 2 SuspendingClock.
    struct timespec now;
    clock_gettime(clock == 1 ? CLOCK_BOOTTIME : CLOCK_MONOTONIC, &now);
    long long remaining = (seconds - (long long)now.tv_sec) * 1000000000LL + (nanoseconds - (long long)now.tv_nsec);
    enqueue_global_with_delay(remaining > 0 ? (unsigned long long)remaining : 0, job, NULL);
}

// A thread holding the turn gives it up while it blocks, and takes it back before it goes on.
static void release_turn(void) {
    collect(0);
    pthread_mutex_lock(&lock);
    turn_taken = 0;
    wake_or_start_thread();
    pthread_mutex_unlock(&lock);
}

static void take_turn(void) {
    pthread_mutex_lock(&lock);
    while (turn_taken) pthread_cond_wait(&turn_free, &lock);
    turn_taken = 1;
    pthread_mutex_unlock(&lock);
    collect_if_measuring();
}

int sem_wait(sem_t *semaphore) {
    static int (*real_sem_wait)(sem_t *) = NULL;
    if (!real_sem_wait) real_sem_wait = (int (*)(sem_t *))dlsym(RTLD_NEXT, "sem_wait");
    if (!holds_turn || sem_trywait(semaphore) == 0) return holds_turn ? 0 : real_sem_wait(semaphore);
    release_turn();
    int result = real_sem_wait(semaphore);
    take_turn();
    return result;
}

int sem_timedwait(sem_t *semaphore, const struct timespec *deadline) {
    static int (*real_sem_timedwait)(sem_t *, const struct timespec *) = NULL;
    if (!real_sem_timedwait) real_sem_timedwait = (int (*)(sem_t *, const struct timespec *))dlsym(RTLD_NEXT, "sem_timedwait");
    if (!holds_turn || sem_trywait(semaphore) == 0) return holds_turn ? 0 : real_sem_timedwait(semaphore, deadline);
    release_turn();
    int result = real_sem_timedwait(semaphore, deadline);
    take_turn();
    return result;
}

__attribute__((constructor)) static void install(void) {
    run_job = (job_run)dlsym(RTLD_DEFAULT, "swift_job_run");
    void **with_delay = dlsym(RTLD_DEFAULT, "swift_task_enqueueGlobalWithDelay_hook");
    void **with_deadline = dlsym(RTLD_DEFAULT, "swift_task_enqueueGlobalWithDeadline_hook");
    if (!run_job || !with_delay || !with_deadline) {
        run_job = NULL; // Not a Swift program: nothing to replace.
        return;
    }
    *with_delay = (void *)enqueue_global_with_delay;
    *with_deadline = (void *)enqueue_global_with_deadline;
}
