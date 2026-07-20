ENTRY(_start)

MEMORY {
    mrom(rx)  : ORIGIN = 0x20000000, LENGTH = 4K
    sram(rwx) : ORIGIN = 0x0f000000, LENGTH = 8K
}

SECTIONS {
    .text : {
        KEEP(*(entry))
        *(.text*)
    } > mrom

    .rodata : {
        *(.rodata*)
    } > mrom

    .data : ALIGN(4) {
        _data_start = .;
        *(.data*)
        *(.sdata*)
        . = ALIGN(4);
        _data_end = .;
    } > sram AT> mrom

    _data_load_start = LOADADDR(.data);

    .bss (NOLOAD) : ALIGN(4) {
        _bss_start = .;
        *(.bss*)
        *(.sbss*)
        *(COMMON)
        . = ALIGN(4);
        _bss_end = .;
    } > sram

    _heap_start    = ALIGN(16);
    _stack_pointer = ORIGIN(sram) + LENGTH(sram);
    _heap_end      = _stack_pointer - 0x1000;

    ASSERT(_heap_start <= _heap_end, "SRAM overflow")
    ASSERT(LOADADDR(.data) + SIZEOF(.data) <= ORIGIN(mrom) + LENGTH(mrom), "MROM overflow")
}
