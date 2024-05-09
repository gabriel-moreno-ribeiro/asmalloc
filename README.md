# asmalloc

> 🇺🇸 [English version below](#english)

Um alocador de memória em assembly x86-64 (NASM, Linux): `malloc`, `free`, `calloc` e `realloc` em cima de `brk` e `mmap`, com free list, divisão de blocos, coalescência de vizinhos, alinhamento de 16 bytes e um spinlock pra threads. Compila como objeto estático pros testes e como biblioteca compartilhada que você pode injetar com `LD_PRELOAD` em programa de verdade.

Esse foi o mais assustador de começar e o mais satisfatório de terminar. Ver o `ls` rodando com um malloc que eu escrevi em assembly é uma sensação que eu recomendo.

```sh
make            # nasm + cc
make test       # harness em C contra os pontos de entrada my_*
make preload    # roda ls, sort e python com o alocador em assembly por baixo

LD_PRELOAD=./libasmalloc.so ls -la
```

## Como um bloco é

```
+0   size       tamanho total do bloco (com header); bit 0 = em uso, bit 1 = mmap
+8   prev_size  tamanho do bloco anterior (0 pro primeiro)
+16  payload    alinhado em 16; blocos livres guardam next/prev da free list aqui
```

- **Heap**: a primeira chamada pede o break atual, alinha, e toda vez que a free list não tem nada grande o suficiente o heap cresce por `brk` em passos de 64 KiB (ou mais pra um pedido grande).
- **malloc**: arredonda pra múltiplo de 16, anda na free list duplamente ligada por first-fit, desliga o bloco e divide o resto como bloco livre novo quando sobram pelo menos 32 bytes.
- **free**: limpa o bit de uso, funde com o bloco seguinte se estiver livre, funde com o anterior usando `prev_size` se estiver livre, conserta o `prev_size` de quem vem depois e empurra na free list. Dois blocos livres adjacentes nunca coexistem.
- **realloc**: mesmo ponteiro se já cabe, cresce no lugar absorvendo um vizinho livre quando dá, senão aloca, copia com `rep movsb` e libera.
- **calloc**: multiplica com detecção de overflow e zera com `rep stosb`.
- **Pedidos grandes** (128 KiB pra cima) ganham uma região `mmap` própria com o bit de mmap no header e voltam com `munmap`.
- **Threads**: spinlock com `xchg` (e `pause`) guardando as estruturas.
- `my_heap_stats` anda no heap e reporta bytes e blocos; os testes usam isso pra provar que os frees voltam a virar um bloco só.

Segue a convenção System V AMD64 e é position-independent (`default rel`), que é o que permite o mesmo fonte virar `.so` exportando `malloc`/`free`/`calloc`/`realloc` quando montado com `-DSHARED`.

O bug que mais demorei pra achar: `realloc(NULL, n)` tem que se comportar como `malloc(n)`, e a minha primeira versão passava o tamanho no registrador errado. Só apareceu rodando o `python` com `LD_PRELOAD`, e achei escrevendo um wrapper em C que logava cada chamada.

Testes: `tests/test_alloc.c` (alinhamento, reuso e coalescência via estatísticas, divisão, `calloc` zerando e overflow, todos os caminhos do `realloc`, o caminho de `mmap`, stress aleatório com verificação de conteúdo, oito threads concorrentes) e `make preload`.

---

## English

A memory allocator in x86-64 assembly (NASM, Linux): `malloc`, `free`, `calloc` and `realloc` on top of `brk` and `mmap`, with a free list, block splitting, coalescing of neighbours, 16-byte alignment and a spinlock for threads. Builds as a static object for the tests and as a shared library you can inject with `LD_PRELOAD` into real programs.

This was the scariest one to start and the most satisfying to finish. Watching `ls` run with a malloc I wrote in assembly is a feeling I recommend.

```sh
make            # nasm + cc
make test       # C harness against the my_* entry points
make preload    # runs ls, sort and python with the assembly allocator underneath

LD_PRELOAD=./libasmalloc.so ls -la
```

## What a block looks like

```
+0   size       total block size (header included); bit 0 = in use, bit 1 = mmap
+8   prev_size  size of the previous block (0 for the first one)
+16  payload    16-aligned; free blocks keep the free list's next/prev here
```

- **Heap**: the first call asks for the current break, aligns it, and every time the free list has nothing big enough the heap grows through `brk` in 64 KiB steps (or more for a large request).
- **malloc**: rounds up to a multiple of 16, walks the doubly linked free list first-fit, unlinks the block and splits the remainder as a new free block when at least 32 bytes are left.
- **free**: clears the in-use bit, merges with the next block if it's free, merges with the previous one using `prev_size` if it's free, fixes the `prev_size` of whoever comes after and pushes onto the free list. Two adjacent free blocks never coexist.
- **realloc**: same pointer if it already fits, grows in place absorbing a free neighbour when possible, otherwise allocates, copies with `rep movsb` and frees.
- **calloc**: multiplies with overflow detection and zeroes with `rep stosb`.
- **Large requests** (128 KiB and up) get their own `mmap` region with the mmap bit in the header and go back with `munmap`.
- **Threads**: a spinlock with `xchg` (and `pause`) guarding the structures.
- `my_heap_stats` walks the heap and reports bytes and blocks; the tests use it to prove the frees turn back into a single block.

Follows the System V AMD64 convention and is position-independent (`default rel`), which is what lets the same source become a `.so` exporting `malloc`/`free`/`calloc`/`realloc` when assembled with `-DSHARED`.

The bug that took me the longest to find: `realloc(NULL, n)` has to behave like `malloc(n)`, and my first version passed the size in the wrong register. It only showed up running `python` with `LD_PRELOAD`, and I found it by writing a C wrapper that logged every call.

Tests: `tests/test_alloc.c` (alignment, reuse and coalescing via the stats, splitting, `calloc` zeroing and overflow, every `realloc` path, the `mmap` path, random stress with content verification, eight concurrent threads) and `make preload`.

MIT.
