// Lookup correctness when pools are added, removed and reused, including more
// simultaneously live pools than the 4096-slot limit reached in BotW 1.8.2.
#include "../nvn/nvn_dirty.h"
#include "../../host/dm.h"
#include <sys/mman.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

module_t g_mod[MAX_MOD];
int g_nmod;
module_t *module_of(const void *p) { (void)p; return NULL; }
void crash_install(void);
uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

static int failures;
#define CHECK(label, condition) do { if (!(condition)) { fprintf(stderr, "%s FAIL\n", label); failures++; } } while (0)

static uint8_t *allocate(size_t n) {
    uint8_t *p = mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (p == MAP_FAILED) { perror("mmap"); exit(2); }
    return p;
}
typedef struct {
    uint8_t *mem;
    size_t size;
    _Atomic int phase;
    int initial, removed, readded;
} reader_arg;
static void *read_across_changes(void *arg) {
    reader_arg *r = arg;
    r->initial = nvn_dirty_tracked(r->mem, r->size);
    atomic_store(&r->phase, 1);
    while (atomic_load(&r->phase) < 2) sched_yield();
    r->removed = nvn_dirty_tracked(r->mem, r->size);
    atomic_store(&r->phase, 3);
    while (atomic_load(&r->phase) < 4) sched_yield();
    r->readded = nvn_dirty_tracked(r->mem, r->size);
    return NULL;
}
static int benchmark(void) {
    size_t pg = (size_t)getpagesize();
    enum { POOLS = 4000, LOOKUPS = 100000 };
    uint8_t *mem = allocate(2 * POOLS * pg);
    for (int i = 0; i < POOLS; i++) nvn_dirty_add_range(mem + 2 * i * pg, pg);
    uint64_t stamp = nvn_dirty_now(), start = now_ns();
    unsigned hits = 0;
    for (unsigned i = 0; i < LOOKUPS; i++) {
        // A working set spread over the latter pools, plus two consecutive
        // queries as used by tex_mtl's tracked / dirty check.
        unsigned index = POOLS - 512 + (i * 17 % 512);
        uint8_t *p = mem + 2 * index * pg + 128;
        hits += nvn_dirty_tracked(p, 256);
        hits += !nvn_dirty_since(p, 256, stamp);
    }
    uint64_t elapsed = now_ns() - start;
    CHECK("all benchmark queries find clean pools", hits == 2 * LOOKUPS);
    printf("Dirty lookup: %.1f ns/query, %.2f ms for %d queries\n", (double)elapsed / (2 * LOOKUPS), elapsed / 1e6, 2 * LOOKUPS);
    for (int i = 0; i < POOLS; i++) nvn_dirty_remove_range(mem + 2 * i * pg);
    munmap(mem, 2 * POOLS * pg);
    return failures != 0;
}
int main(int argc, char **argv) {
    crash_install();
    if (argc == 2 && !strcmp(argv[1], "--bench")) return benchmark();
    size_t pg = (size_t)getpagesize();
    enum { POOLS = 5000 };
    uint8_t *mem = allocate((2 * POOLS + 8) * pg);
    uint8_t *later = mem + (2 * POOLS + 2) * pg;
    CHECK("unregistered span", !nvn_dirty_tracked(later, pg));
    nvn_dirty_add_range(later, pg);
    CHECK("register after a missed lookup", nvn_dirty_tracked(later, pg));
    CHECK("short pool cannot cover a longer span", !nvn_dirty_tracked(later, 2 * pg));
    nvn_dirty_remove_range(later);
    CHECK("remove a previously found span", !nvn_dirty_tracked(later, pg));
    for (int i = 0; i < POOLS; i++) nvn_dirty_add_range(mem + 2 * i * pg, pg);
    uint8_t *last = mem + 2 * (POOLS - 1) * pg;
    CHECK("5000 simultaneous pools remain tracked", nvn_dirty_tracked(last, pg));
    uint64_t stamp = nvn_dirty_now();
    CHECK("unchanged late pool is clean", !nvn_dirty_since(last, pg, stamp));
    nvn_dirty_protect(last, pg);
    last[0] = 42;
    CHECK("late pool write is detected", nvn_dirty_since(last, pg, stamp));
    CHECK("bounds include length on a cached page", !nvn_dirty_tracked(last, 2 * pg));
    CHECK("shorter span still tracked", nvn_dirty_tracked(last, pg));
    nvn_dirty_remove_range(last);
    CHECK("cached removed pool no longer tracked", !nvn_dirty_tracked(last, pg));
    nvn_dirty_add_range(later, pg);   // Reuses the removed slot with different bounds.
    CHECK("slot reuse does not resurrect old bounds", !nvn_dirty_tracked(last, pg));
    CHECK("reused slot holds its new pool", nvn_dirty_tracked(later, pg));
    reader_arg reader = {.mem = later, .size = pg};
    pthread_t thread;
    if (pthread_create(&thread, NULL, read_across_changes, &reader)) { perror("pthread_create"); return 2; }
    while (atomic_load(&reader.phase) < 1) sched_yield();
    nvn_dirty_remove_range(later);
    atomic_store(&reader.phase, 2);
    while (atomic_load(&reader.phase) < 3) sched_yield();
    nvn_dirty_add_range(later, pg);
    atomic_store(&reader.phase, 4);
    pthread_join(thread, NULL);
    CHECK("another thread initially finds the pool", reader.initial);
    CHECK("another thread observes pool removal", !reader.removed);
    CHECK("another thread observes registration after a miss", reader.readded);
    nvn_dirty_remove_range(later);
    for (int i = 0; i < POOLS - 1; i++) nvn_dirty_remove_range(mem + 2 * i * pg);
    munmap(mem, (2 * POOLS + 8) * pg);
    printf("Dirty lookup correctness %s\n", failures ? "FAIL" : "PASS");
    return failures != 0;
}
