.section entry, "ax"
.globl _start
.type _start, @function

_start:
    la sp, _stack_pointer
    mv s0, zero

    # copy initialized .data from Flash load address to PSRAM runtime address
    la t0, _data_load_start
    la t1, _data_start
    la t2, _data_end
1:
    bgeu t1, t2, 2f
    lbu t3, 0(t0)
    sb t3, 0(t1)
    addi t0, t0, 1
    addi t1, t1, 1
    j 1b

    # clear .bss
2:
    la t1, _bss_start
    la t2, _bss_end
3:
    bgeu t1, t2, 4f
    sb zero, 0(t1)
    addi t1, t1, 1
    j 3b

4:
    call _trm_init

5:
    j 5b
