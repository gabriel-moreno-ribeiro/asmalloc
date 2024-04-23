; asmalloc - a memory allocator written from scratch in x86-64 assembly
; (NASM, Linux, System V ABI).
;
; Layout of a block:
;   +0   size      total block size in bytes (header included); bit 0 = in use,
;                  bit 1 = obtained with mmap (freed with munmap)
;   +8   prev_size size of the block just before this one in the heap (0 = first)
;   +16  payload   16-byte aligned; free blocks keep the free-list links here:
;                  +16 next_free, +24 prev_free
;
; The heap is one contiguous region: 256 MiB of address space reserved with
; mmap (MAP_NORESERVE, so pages only cost memory once touched) and handed
; out in 64 KiB steps as the heap grows. Free blocks are kept in a doubly
; linked list searched first-fit; blocks are split when the remainder is
; large enough and merged with free neighbours on free (boundary tags).
; Requests of 128 KiB or more get their own mmap region.
; A spinlock makes every operation safe to call from several threads.

default rel

%define HEADER_SIZE     16
%define MIN_BLOCK       32
%define ALIGNMENT       16
%define MMAP_THRESHOLD  131072
%define HEAP_GROW       65536
%define HEAP_RESERVE    0x10000000
%define FLAG_USED       1
%define FLAG_MMAP       2

%define SYS_MMAP        9
%define SYS_MUNMAP      11

%define PROT_READ_WRITE 3
%define MAP_PRIVATE_ANON 0x22
%define MAP_NORESERVE   0x4000

section .bss
    heap_start:  resq 1     ; first block
    heap_end:    resq 1     ; end of the part of the reservation in use
    heap_limit:  resq 1     ; end of the reserved address range
    last_block:  resq 1     ; highest block in the heap (needed for prev_size bookkeeping)
    free_head:   resq 1     ; head of the free list
    lock_word:   resq 1

section .text

global my_malloc
global my_free
global my_calloc
global my_realloc
global my_heap_stats

%ifdef SHARED
global malloc:function
global free:function
global calloc:function
global realloc:function
global malloc_usable_size:function
malloc:  jmp my_malloc
free:    jmp my_free
calloc:  jmp my_calloc
realloc: jmp my_realloc
malloc_usable_size: jmp my_usable_size
%endif

; size_t my_usable_size(void *p): payload capacity of one of our blocks, 0 otherwise
global my_usable_size
my_usable_size:
    test    rdi, rdi
    jz      .zero
    lea     rax, [rdi - HEADER_SIZE]
    test    qword [rax], FLAG_MMAP
    jz      .heap
    test    rax, 4095
    jnz     .zero
    jmp     .size
.heap:
    cmp     rax, [heap_start]
    jb      .zero
    cmp     rax, [heap_end]
    jae     .zero
.size:
    mov     rax, [rax]
    and     rax, ~15
    sub     rax, HEADER_SIZE
    ret
.zero:
    xor     eax, eax
    ret

; ---------------------------------------------------------------------------
; spinlock
; ---------------------------------------------------------------------------
lock_acquire:
.spin:
    mov     eax, 1
    xchg    eax, [lock_word]
    test    eax, eax
    jz      .done
    pause
    jmp     .spin
.done:
    ret

lock_release:
    mov     qword [lock_word], 0
    ret

; ---------------------------------------------------------------------------
; free-list helpers (block pointer in rdi)
; ---------------------------------------------------------------------------
list_insert:                     ; push block at the head of the free list
    mov     rax, [free_head]
    mov     [rdi + 16], rax      ; block.next = head
    mov     qword [rdi + 24], 0  ; block.prev = NULL
    test    rax, rax
    jz      .set_head
    mov     [rax + 24], rdi      ; head.prev = block
.set_head:
    mov     [free_head], rdi
    ret

list_remove:                     ; unlink block from the free list
    mov     rax, [rdi + 16]      ; next
    mov     rcx, [rdi + 24]      ; prev
    test    rcx, rcx
    jz      .fix_head
    mov     [rcx + 16], rax      ; prev.next = next
    jmp     .fix_next
.fix_head:
    mov     [free_head], rax
.fix_next:
    test    rax, rax
    jz      .done
    mov     [rax + 24], rcx      ; next.prev = prev
.done:
    ret

; next_block(rdi) -> rax, or 0 when rdi is the last block
next_block:
    mov     rax, [rdi]
    and     rax, ~15
    add     rax, rdi
    cmp     rax, [heap_end]
    jb      .ok
    xor     eax, eax
.ok:
    ret

; ---------------------------------------------------------------------------
; heap growth: rdi = bytes needed (multiple of 16). Returns new block in rax
; (size field set, marked free but not in the list) or 0 on failure.
; ---------------------------------------------------------------------------
grow_heap:
    push    rbx
    push    r12
    mov     r12, rdi
    cmp     r12, HEAP_GROW
    jae     .sized
    mov     r12, HEAP_GROW
.sized:
    mov     rbx, [heap_end]
    test    rbx, rbx
    jnz     .have_heap
    ; first call: reserve the address range for the whole heap
    xor     edi, edi             ; addr
    mov     rsi, HEAP_RESERVE
    mov     edx, PROT_READ_WRITE
    mov     r10d, MAP_PRIVATE_ANON | MAP_NORESERVE
    mov     r8, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4095
    jae     .fail
    mov     [heap_start], rax
    mov     [heap_end], rax
    lea     rcx, [rax + HEAP_RESERVE]
    mov     [heap_limit], rcx
    mov     rbx, rax
.have_heap:
    lea     rcx, [rbx + r12]
    cmp     rcx, [heap_limit]
    ja      .fail                ; reservation exhausted
    mov     [heap_end], rcx
    ; new block at rbx
    mov     [rbx], r12           ; size, flags clear
    mov     rax, [last_block]
    test    rax, rax
    jz      .first
    mov     rcx, [rax]
    and     rcx, ~15
    mov     [rbx + 8], rcx       ; prev_size = size of previous last block
    jmp     .link
.first:
    mov     qword [rbx + 8], 0
.link:
    mov     [last_block], rbx
    mov     rax, rbx
    jmp     .done
.fail:
    xor     eax, eax
.done:
    pop     r12
    pop     rbx
    ret

; ---------------------------------------------------------------------------
; split_block: rdi = block (free, not in list), rsi = size to keep.
; If the remainder is at least MIN_BLOCK, carves a new free block after it
; and inserts that into the free list.
; ---------------------------------------------------------------------------
split_block:
    push    rbx
    push    r12
    mov     rbx, rdi
    mov     r12, rsi
    mov     rax, [rbx]
    and     rax, ~15             ; full size
    sub     rax, r12             ; remainder
    cmp     rax, MIN_BLOCK
    jb      .done
    ; remainder block at rbx + r12
    lea     rcx, [rbx + r12]
    mov     [rcx], rax           ; size, free
    mov     [rcx + 8], r12       ; prev_size = kept size
    mov     [rbx], r12           ; shrink this block (flags will be set by caller)
    ; the block after the remainder (if any) must point back at the remainder
    cmp     rbx, [last_block]
    jne     .fix_following
    mov     [last_block], rcx
    jmp     .insert
.fix_following:
    lea     rdx, [rcx + rax]     ; following block
    mov     [rdx + 8], rax
.insert:
    mov     rdi, rcx
    call    list_insert
.done:
    pop     r12
    pop     rbx
    ret

; ---------------------------------------------------------------------------
; void *my_malloc(size_t n)
; ---------------------------------------------------------------------------
my_malloc:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    test    r12, r12
    jnz     .nonzero
    mov     r12, 1               ; malloc(0) returns a unique, freeable pointer
.nonzero:
    ; overflow guard: refuse absurd sizes
    mov     rax, 0x7fffffffffff
    cmp     r12, rax
    ja      .fail
    cmp     r12, MMAP_THRESHOLD
    jae     .use_mmap
    ; need = align16(n) + header, at least MIN_BLOCK
    lea     r13, [r12 + 15]
    and     r13, ~15
    add     r13, HEADER_SIZE
    cmp     r13, MIN_BLOCK
    jae     .search
    mov     r13, MIN_BLOCK
.search:
    call    lock_acquire
    mov     rbx, [free_head]
.loop:
    test    rbx, rbx
    jz      .grow
    mov     rax, [rbx]
    and     rax, ~15
    cmp     rax, r13
    jae     .found
    mov     rbx, [rbx + 16]
    jmp     .loop
.found:
    mov     rdi, rbx
    call    list_remove
    jmp     .use
.grow:
    mov     rdi, r13
    call    grow_heap
    test    rax, rax
    jz      .unlock_fail
    mov     rbx, rax
.use:
    mov     rdi, rbx
    mov     rsi, r13
    call    split_block
    or      qword [rbx], FLAG_USED
    call    lock_release
    lea     rax, [rbx + HEADER_SIZE]
    jmp     .done
.unlock_fail:
    call    lock_release
.fail:
    xor     eax, eax
    jmp     .done
.use_mmap:
    ; map align4096(n + header)
    lea     rsi, [r12 + HEADER_SIZE + 4095]
    and     rsi, ~4095
    mov     r13, rsi
    xor     edi, edi             ; addr
    mov     edx, PROT_READ_WRITE
    mov     r10d, MAP_PRIVATE_ANON
    mov     r8, -1               ; fd
    xor     r9d, r9d             ; offset
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4095
    jae     .fail                ; error code
    mov     rcx, r13
    or      rcx, FLAG_USED | FLAG_MMAP
    mov     [rax], rcx
    mov     qword [rax + 8], 0
    add     rax, HEADER_SIZE
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

; ---------------------------------------------------------------------------
; void my_free(void *p)
; ---------------------------------------------------------------------------
my_free:
    test    rdi, rdi
    jz      .ret
    push    rbx
    push    r12
    lea     rbx, [rdi - HEADER_SIZE]
    mov     rax, [rbx]
    test    rax, FLAG_MMAP
    jz      .check_heap
    test    rbx, 4095            ; our mmap blocks always start on a page
    jnz     .out
    jmp     .unmap
.check_heap:
    ; pointers that did not come from this heap (for example handed out by
    ; the dynamic loader before we were loaded) are ignored rather than trusted
    cmp     rbx, [heap_start]
    jb      .out
    cmp     rbx, [heap_end]
    jae     .out
    call    lock_acquire
    and     qword [rbx], ~FLAG_USED
    ; merge with the next block when it is free
    mov     rdi, rbx
    call    next_block
    test    rax, rax
    jz      .merge_prev
    test    qword [rax], FLAG_USED
    jnz     .merge_prev
    mov     rdi, rax
    mov     r12, rax
    call    list_remove
    mov     rax, [r12]
    and     rax, ~15
    add     [rbx], rax           ; rbx.size += next.size
    cmp     r12, [last_block]
    jne     .merge_prev
    mov     [last_block], rbx
.merge_prev:
    mov     rax, [rbx + 8]       ; prev_size
    test    rax, rax
    jz      .insert
    mov     r12, rbx
    sub     r12, rax             ; prev block
    test    qword [r12], FLAG_USED
    jnz     .insert
    mov     rdi, r12
    call    list_remove
    mov     rax, [rbx]
    and     rax, ~15
    add     [r12], rax           ; prev.size += size
    cmp     rbx, [last_block]
    jne     .prev_merged
    mov     [last_block], r12
.prev_merged:
    mov     rbx, r12
.insert:
    ; the block after the merged block must know its new size
    mov     rdi, rbx
    call    next_block
    test    rax, rax
    jz      .push
    mov     rcx, [rbx]
    and     rcx, ~15
    mov     [rax + 8], rcx
.push:
    mov     rdi, rbx
    call    list_insert
    call    lock_release
    jmp     .out
.unmap:
    and     rax, ~15
    mov     rdi, rbx
    mov     rsi, rax
    mov     eax, SYS_MUNMAP
    syscall
.out:
    pop     r12
    pop     rbx
.ret:
    ret

; ---------------------------------------------------------------------------
; void *my_calloc(size_t count, size_t size)
; ---------------------------------------------------------------------------
my_calloc:
    push    rbx
    push    r12
    mov     rax, rdi
    mul     rsi                  ; rdx:rax = count * size
    jc      .overflow
    test    rdx, rdx
    jnz     .overflow
    mov     r12, rax
    mov     rdi, rax
    call    my_malloc
    test    rax, rax
    jz      .done
    mov     rbx, rax
    mov     rdi, rax
    mov     rcx, r12
    xor     eax, eax
    rep stosb                    ; zero the payload
    mov     rax, rbx
    jmp     .done
.overflow:
    xor     eax, eax
.done:
    pop     r12
    pop     rbx
    ret

; ---------------------------------------------------------------------------
; void *my_realloc(void *p, size_t n)
; ---------------------------------------------------------------------------
my_realloc:
    test    rdi, rdi
    jnz     .have_ptr
    mov     rdi, rsi             ; realloc(NULL, n) == malloc(n)
    jmp     my_malloc
.have_ptr:
    test    rsi, rsi
    jnz     .resize
    call    my_free              ; realloc(p, 0) frees
    xor     eax, eax
    ret
.resize:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     rbx, rdi
    mov     r12, rsi
    ; is this one of our blocks? (mmap block on a page boundary, or inside the heap)
    lea     rax, [rbx - HEADER_SIZE]
    test    qword [rax], FLAG_MMAP
    jz      .check_heap
    test    rax, 4095
    jz      .ours
    jmp     .foreign
.check_heap:
    cmp     rax, [heap_start]
    jb      .foreign
    cmp     rax, [heap_end]
    jae     .foreign
.ours:
    mov     rax, [rbx - HEADER_SIZE]
    and     rax, ~15
    sub     rax, HEADER_SIZE     ; current payload capacity
    mov     r13, rax
    cmp     r13, r12
    jae     .keep                ; already big enough
    test    qword [rbx - HEADER_SIZE], FLAG_MMAP
    jnz     .move
    ; try to grow into a free next block (in place)
    lea     r14, [r12 + 15]
    and     r14, ~15
    add     r14, HEADER_SIZE     ; needed total size
    call    lock_acquire
    lea     rdi, [rbx - HEADER_SIZE]
    call    next_block
    test    rax, rax
    jz      .no_room
    test    qword [rax], FLAG_USED
    jnz     .no_room
    mov     rcx, [rax]
    and     rcx, ~15
    mov     rdx, [rbx - HEADER_SIZE]
    and     rdx, ~15
    add     rdx, rcx             ; combined size
    cmp     rdx, r14
    jb      .no_room
    ; absorb the next block
    mov     rdi, rax
    push    rax
    call    list_remove
    pop     rax
    lea     rdi, [rbx - HEADER_SIZE]
    mov     rcx, [rax]
    and     rcx, ~15
    mov     rdx, [rdi]
    and     rdx, ~15
    add     rdx, rcx
    mov     [rdi], rdx           ; free for a moment, split_block needs the raw size
    cmp     rax, [last_block]
    jne     .absorbed
    mov     [last_block], rdi
.absorbed:
    mov     rsi, r14
    call    split_block
    lea     rdi, [rbx - HEADER_SIZE]
    or      qword [rdi], FLAG_USED
    ; fix prev_size of whatever follows now
    call    next_block
    test    rax, rax
    jz      .grown
    lea     rdi, [rbx - HEADER_SIZE]
    mov     rcx, [rdi]
    and     rcx, ~15
    mov     [rax + 8], rcx
.grown:
    call    lock_release
    mov     rax, rbx
    jmp     .done
.no_room:
    call    lock_release
.move:
    mov     rdi, r12
    call    my_malloc
    test    rax, rax
    jz      .done
    mov     r14, rax
    ; copy min(old capacity, n) bytes
    mov     rcx, r13
    cmp     rcx, r12
    jbe     .copy
    mov     rcx, r12
.copy:
    mov     rdi, r14
    mov     rsi, rbx
    rep movsb
    mov     rdi, rbx
    call    my_free
    mov     rax, r14
    jmp     .done
.foreign:
    ; not our memory: give the caller a fresh block with the requested bytes copied over
    mov     rdi, r12
    call    my_malloc
    test    rax, rax
    jz      .done
    mov     rdi, rax
    mov     rsi, rbx
    mov     rcx, r12
    push    rax
    rep movsb
    pop     rax
    jmp     .done
.keep:
    mov     rax, rbx
.done:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ---------------------------------------------------------------------------
; void my_heap_stats(struct { size_t heap_bytes, used_bytes, free_bytes,
;                             used_blocks, free_blocks; } *out)
; Walks every block of the brk heap (mmap regions are not counted).
; ---------------------------------------------------------------------------
my_heap_stats:
    push    rbx
    push    r12
    mov     r12, rdi
    call    lock_acquire
    xor     eax, eax
    mov     [r12], rax
    mov     [r12 + 8], rax
    mov     [r12 + 16], rax
    mov     [r12 + 24], rax
    mov     [r12 + 32], rax
    mov     rbx, [heap_start]
    test    rbx, rbx
    jz      .done
    mov     rax, [heap_end]
    sub     rax, rbx
    mov     [r12], rax
.walk:
    cmp     rbx, [heap_end]
    jae     .done
    mov     rax, [rbx]
    mov     rcx, rax
    and     rcx, ~15
    test    rax, FLAG_USED
    jz      .free_block
    add     [r12 + 8], rcx
    inc     qword [r12 + 24]
    jmp     .next
.free_block:
    add     [r12 + 16], rcx
    inc     qword [r12 + 32]
.next:
    add     rbx, rcx
    jmp     .walk
.done:
    call    lock_release
    pop     r12
    pop     rbx
    ret

section .note.GNU-stack noalloc noexec nowrite progbits
