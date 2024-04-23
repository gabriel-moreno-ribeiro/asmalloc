NASM ?= nasm
CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra -Werror

.PHONY: all test preload clean

all: test_alloc libasmalloc.so

alloc.o: src/alloc.asm
	$(NASM) -f elf64 -o alloc.o src/alloc.asm

alloc_shared.o: src/alloc.asm
	$(NASM) -f elf64 -DSHARED -o alloc_shared.o src/alloc.asm

test_alloc: alloc.o tests/test_alloc.c
	$(CC) $(CFLAGS) -pthread -o test_alloc tests/test_alloc.c alloc.o

# A drop-in replacement for the C library allocator: LD_PRELOAD=./libasmalloc.so <program>
libasmalloc.so: alloc_shared.o
	$(CC) -shared -nostdlib -o libasmalloc.so alloc_shared.o

test: test_alloc
	./test_alloc

preload: libasmalloc.so
	LD_PRELOAD=./libasmalloc.so ls -la | head -3
	LD_PRELOAD=./libasmalloc.so sort -r src/alloc.asm | head -2
	LD_PRELOAD=./libasmalloc.so python3 -c "print(sum(range(1000000)))" || true

clean:
	rm -f alloc.o alloc_shared.o test_alloc libasmalloc.so
