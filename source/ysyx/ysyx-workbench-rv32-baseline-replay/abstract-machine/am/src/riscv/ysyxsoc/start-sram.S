.section entry, "ax"
.globl _start
.type _start, @function

_start:
    la sp, _stack_pointer
    mv s0, zero

    # Copy the linked SRAM image (.text/.rodata/.data) from Flash to SRAM.
    # The linker aligns both ends to 4 bytes, so word accesses are sufficient.
    la t0, _sram_image_load_start
    la t1, _sram_image_start
    la t2, _sram_image_end
1:
    bgeu t1, t2, 2f
    lw t3, 0(t0)
    sw t3, 0(t1)
    addi t0, t0, 4
    addi t1, t1, 4
    j 1b

    # BSS has no load image. Initialize it directly in SRAM.
2:
    la t1, _bss_start
    la t2, _bss_end
3:
    bgeu t1, t2, 4f
    sw zero, 0(t1)
    addi t1, t1, 4
    j 3b

    # Make stores to the instruction image visible before fetching from SRAM.
4:
    fence.i
    la t0, _trm_init
    jr t0

5:
    j 5b
