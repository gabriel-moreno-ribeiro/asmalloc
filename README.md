# asmalloc

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

**EN:** a memory allocator in x86-64 NASM assembly for Linux: first-fit free list with splitting and coalescing over a `brk` heap, `mmap` for large blocks, 16-byte alignment, `realloc` growing in place, `calloc` with overflow checks and an `xchg` spinlock, exported as a `LD_PRELOAD`-able shared library that runs real programs. C test harness plus multithreaded stress tests. MIT.
