.section entry, "ax"
.globl _start
.type _start, @function

_start:
    /* Keep the runtime stack in the low-latency on-chip SRAM. */
    la sp, _stack_pointer
    mv s0, zero

    /* Copy the linked runtime image from Flash LMA to SDRAM VMA. */
    la t0, _sdram_image_load_start
    la t1, _sdram_image_start
    la t2, _sdram_image_end
1:
    bgeu t1, t2, 2f
    lw t3, 0(t0)
    sw t3, 0(t1)
    addi t0, t0, 4
    addi t1, t1, 4
    j 1b

    /* BSS has no Flash payload and is initialized directly in SDRAM. */
2:
    la t1, _bss_start
    la t2, _bss_end
3:
    bgeu t1, t2, 4f
    sw zero, 0(t1)
    addi t1, t1, 4
    j 3b

    /* Make the copied instructions visible before fetching from SDRAM. */
4:
    fence.i
    la t0, _trm_init
    jr t0

5:
    j 5b
