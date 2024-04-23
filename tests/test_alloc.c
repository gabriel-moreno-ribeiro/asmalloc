/* Exercises the assembly allocator through its my_* entry points. */
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void *my_malloc(size_t n);
void my_free(void *p);
void *my_calloc(size_t count, size_t size);
void *my_realloc(void *p, size_t n);
size_t my_usable_size(void *p);

struct heap_stats {
    size_t heap_bytes, used_bytes, free_bytes, used_blocks, free_blocks;
};
void my_heap_stats(struct heap_stats *out);

static int passed = 0, failed = 0;
#define CHECK(name, cond)                                                     \
    do {                                                                      \
        if (cond) passed++;                                                   \
        else { failed++; printf("FAIL %s (line %d)\n", name, __LINE__); }     \
    } while (0)

static int aligned16(const void *p) { return ((uintptr_t)p & 15) == 0; }

static void fill(unsigned char *p, size_t n, unsigned char seed) {
    for (size_t i = 0; i < n; i++) p[i] = (unsigned char)(seed + i);
}
static int check_fill(const unsigned char *p, size_t n, unsigned char seed) {
    for (size_t i = 0; i < n; i++)
        if (p[i] != (unsigned char)(seed + i)) return 0;
    return 1;
}

static void test_basics(void) {
    char *a = my_malloc(10);
    char *b = my_malloc(100);
    char *c = my_malloc(1000);
    CHECK("malloc returns memory", a && b && c);
    CHECK("16-byte aligned", aligned16(a) && aligned16(b) && aligned16(c));
    CHECK("distinct blocks", a != b && b != c && (b - a) >= 32);
    fill((unsigned char *)a, 10, 1);
    fill((unsigned char *)b, 100, 2);
    fill((unsigned char *)c, 1000, 3);
    CHECK("no overlap", check_fill((unsigned char *)a, 10, 1) && check_fill((unsigned char *)b, 100, 2) && check_fill((unsigned char *)c, 1000, 3));
    struct heap_stats s;
    my_heap_stats(&s);
    CHECK("stats count used blocks", s.used_blocks >= 3 && s.used_bytes >= 32 + 112 + 1008);
    my_free(b);
    my_heap_stats(&s);
    CHECK("free block appears in stats", s.free_blocks >= 1);
    my_free(a);
    my_free(c);
    my_free(NULL);
    my_heap_stats(&s);
    CHECK("everything coalesced into one free block", s.free_blocks == 1 && s.used_blocks == 0 && s.free_bytes == s.heap_bytes);
    void *z = my_malloc(0);
    CHECK("malloc(0) gives a usable pointer", z != NULL);
    my_free(z);
}

static void test_reuse_and_coalescing(void) {
    struct heap_stats before, after;
    void *a = my_malloc(200);
    void *b = my_malloc(200);
    void *c = my_malloc(200);
    my_heap_stats(&before);
    my_free(b);
    void *b2 = my_malloc(150);
    CHECK("freed block is reused (first fit)", b2 == b);
    my_free(b2);
    my_free(a);
    /* a and b are now merged: a 450+ byte allocation must fit there without growing the heap */
    void *big = my_malloc(400);
    my_heap_stats(&after);
    CHECK("neighbours merged so a larger request fits", big == a && after.heap_bytes == before.heap_bytes);
    my_free(big);
    my_free(c);
    my_heap_stats(&after);
    CHECK("heap fully free again", after.free_blocks == 1 && after.used_blocks == 0);
}

static void test_split(void) {
    void *big = my_malloc(1024);
    my_free(big);
    void *small = my_malloc(64);
    CHECK("small request splits the big free block", small == big);
    struct heap_stats s;
    my_heap_stats(&s);
    CHECK("remainder stays free", s.free_blocks >= 1 && s.free_bytes >= 900);
    my_free(small);
}

static void test_calloc(void) {
    unsigned char *p = my_malloc(256);
    memset(p, 0xAB, 256);
    my_free(p);
    unsigned char *z = my_calloc(16, 16);
    int zero = 1;
    for (int i = 0; i < 256; i++) zero &= z[i] == 0;
    CHECK("calloc zeroes reused memory", z && zero);
    my_free(z);
    CHECK("calloc overflow returns NULL", my_calloc((size_t)1 << 40, (size_t)1 << 40) == NULL);
    void *empty = my_calloc(0, 0);
    CHECK("calloc(0, 0) works", empty != NULL);
    my_free(empty);
}

static void test_realloc(void) {
    unsigned char *p = my_malloc(40);
    fill(p, 40, 9);
    unsigned char *q = my_realloc(p, 20);
    CHECK("shrinking keeps the pointer", q == p && check_fill(q, 20, 9));
    /* grow in place: the next block is free */
    unsigned char *r = my_realloc(q, 300);
    CHECK("growing into free space keeps the data", r && check_fill(r, 40, 9));
    /* block a block after it, then grow: must move */
    void *blocker = my_malloc(16);
    unsigned char *m = my_realloc(r, 5000);
    CHECK("realloc moves when it cannot grow in place", m && m != r && check_fill(m, 40, 9));
    my_free(blocker);
    my_free(m);
    unsigned char *fresh = my_realloc(NULL, 312);
    CHECK("realloc(NULL) is malloc", fresh != NULL && my_usable_size(fresh) >= 312);
    fill(fresh, 312, 4);
    CHECK("realloc(NULL) block is fully usable", check_fill(fresh, 312, 4));
    my_free(fresh);
    CHECK("usable size of a foreign pointer is 0", my_usable_size(&passed) == 0);
    void *t = my_malloc(10);
    CHECK("realloc(p, 0) frees and returns NULL", my_realloc(t, 0) == NULL);
}

static void test_mmap_path(void) {
    size_t big = 1 << 20; /* 1 MiB: above the mmap threshold */
    struct heap_stats before, after;
    my_heap_stats(&before);
    unsigned char *p = my_malloc(big);
    CHECK("large allocation works", p && aligned16(p));
    fill(p, big, 5);
    CHECK("large allocation is writable", check_fill(p, big, 5));
    my_heap_stats(&after);
    CHECK("large blocks do not use the brk heap", after.heap_bytes == before.heap_bytes);
    unsigned char *q = my_realloc(p, big * 2);
    CHECK("realloc of a mapped block keeps the data", q && check_fill(q, big, 5));
    my_free(q);
}

static void test_stress(void) {
    enum { N = 400 };
    unsigned char *ptrs[N];
    size_t sizes[N];
    srand(12345);
    for (int i = 0; i < N; i++) {
        sizes[i] = 1 + (size_t)rand() % 2000;
        ptrs[i] = my_malloc(sizes[i]);
        fill(ptrs[i], sizes[i], (unsigned char)i);
    }
    int ok = 1;
    for (int round = 0; round < 2000; round++) {
        int i = rand() % N;
        ok &= check_fill(ptrs[i], sizes[i], (unsigned char)i);
        my_free(ptrs[i]);
        sizes[i] = 1 + (size_t)rand() % 3000;
        ptrs[i] = rand() % 3 == 0 ? my_calloc(1, sizes[i]) : my_malloc(sizes[i]);
        ok &= ptrs[i] != NULL && aligned16(ptrs[i]);
        fill(ptrs[i], sizes[i], (unsigned char)i);
    }
    for (int i = 0; i < N; i++) {
        ok &= check_fill(ptrs[i], sizes[i], (unsigned char)i);
        my_free(ptrs[i]);
    }
    CHECK("random stress: no corruption", ok);
    struct heap_stats s;
    my_heap_stats(&s);
    CHECK("stress leaves the heap fully free", s.used_blocks == 0);
    CHECK("heap stayed bounded", s.heap_bytes < 8 * 1024 * 1024);
}

static void *thread_body(void *arg) {
    int id = (int)(intptr_t)arg;
    for (int round = 0; round < 500; round++) {
        size_t n = 16 + (size_t)((round * 7 + id * 13) % 500);
        unsigned char *p = my_malloc(n);
        if (!p) return (void *)1;
        fill(p, n, (unsigned char)id);
        if (!check_fill(p, n, (unsigned char)id)) return (void *)1;
        my_free(p);
    }
    return NULL;
}

static void test_threads(void) {
    pthread_t threads[8];
    for (int i = 0; i < 8; i++) pthread_create(&threads[i], NULL, thread_body, (void *)(intptr_t)i);
    int ok = 1;
    for (int i = 0; i < 8; i++) {
        void *result;
        pthread_join(threads[i], &result);
        ok &= result == NULL;
    }
    CHECK("eight threads allocate concurrently without corruption", ok);
    struct heap_stats s;
    my_heap_stats(&s);
    CHECK("threads freed everything", s.used_blocks == 0);
}

int main(void) {
    test_basics();
    test_reuse_and_coalescing();
    test_split();
    test_calloc();
    test_realloc();
    test_mmap_path();
    test_stress();
    test_threads();
    printf("%d passed, %d failed\n", passed, failed);
    return failed == 0 ? 0 : 1;
}
