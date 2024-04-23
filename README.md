# asmalloc

A memory allocator written from scratch in x86-64 assembly (NASM, Linux):
`malloc`, `free`, `calloc` and `realloc` on top of the `brk` and `mmap`
system calls, with a free list, block splitting, coalescing of neighbours,
16-byte alignment and a spinlock for threads. It builds as a static object
for the tests and as a shared library you can `LD_PRELOAD` under real
programs.

```sh
make            # nasm + cc
make test       # C test harness against the my_* entry points
make preload    # runs ls, sort and python with the assembly allocator underneath

LD_PRELOAD=./libasmalloc.so ls -la
```

## How it works

Each block starts with a 16-byte header:

```
+0   size       total size of the block (header included); bit 0 = in use, bit 1 = mmap
+8   prev_size  size of the block before this one (0 for the first block)
+16  payload    16-byte aligned; free blocks keep next/prev free-list pointers here
```

- **Heap**: the first call asks the kernel for the current break, aligns
  it, and every time the free list has nothing big enough the heap grows by
  `brk` in 64 KiB steps (or more for a single large request).
- **malloc**: rounds the request up to a multiple of 16, walks the doubly
  linked free list first-fit, unlinks the block, and splits off the tail as a
  new free block when at least 32 bytes are left over.
- **free**: clears the in-use bit, merges with the following block if it is
  free (unlinking it), merges with the previous block using `prev_size` if
  that one is free, fixes the `prev_size` of whatever follows, and pushes the
  result on the free list. Adjacent free blocks therefore never coexist.
- **realloc**: returns the same pointer when the block is already big
  enough, grows in place by absorbing a free neighbour when it can, and
  otherwise allocates, copies with `rep movsb` and frees.
- **calloc**: multiplies with overflow detection, then zeroes with `rep stosb`.
- **Large requests** (128 KiB and up) get a private anonymous `mmap` region
  with the mmap bit set in the header, and are returned with `munmap`.
- **Threads**: an `xchg`-based spinlock (with `pause`) guards the heap
  structures, so the shared library works under multithreaded programs.
- `my_heap_stats` walks the heap and reports bytes and block counts; the
  tests use it to prove that frees coalesce back into one block.

The assembly follows the System V AMD64 calling convention and is
position-independent (`default rel`), which is what lets the same source
become a `.so` with `malloc`/`free`/`calloc`/`realloc` exported when
assembled with `-DSHARED`.

## Tests

`tests/test_alloc.c` checks alignment and non-overlap, reuse and coalescing
via heap statistics, splitting, `calloc` zeroing and overflow, every
`realloc` path (shrink, grow in place, move, NULL, zero), the `mmap` path for
large blocks, a randomised stress test with content verification, and eight
threads allocating concurrently. `make preload` then runs real programs
with the allocator injected.

## License

MIT
