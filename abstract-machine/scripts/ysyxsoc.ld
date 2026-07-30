ENTRY(_start)

MEMORY {
    flash (rx)  : ORIGIN = 0x30000000, LENGTH = 16M
    sram  (rwx) : ORIGIN = 0x0f000000, LENGTH = 8K
    psram (rwx) : ORIGIN = 0x80000000, LENGTH = 4M
}

SECTIONS {
    .text : ALIGN(4) {
        KEEP(*(entry))
        *(.text*)
    } > flash

    .rodata : ALIGN(4) {
        *(.rodata*)
        *(.srodata*)
    } > flash

    .data : ALIGN(4) {
        _data_start = .;
        *(.data*)
        *(.sdata*)
        . = ALIGN(4);
        _data_end = .;
    } > psram AT> flash

    _data_load_start = LOADADDR(.data);

    .bss (NOLOAD) : ALIGN(4) {
        _bss_start = .;
        *(.bss*)
        *(.sbss*)
        *(COMMON)
        . = ALIGN(4);
        _bss_end = .;
    } > psram

    _heap_start    = ALIGN(16);
    _heap_end      = ORIGIN(psram) + LENGTH(psram);

    _stack_bottom  = ORIGIN(sram);
    _stack_pointer = ORIGIN(sram) + LENGTH(sram);

    ASSERT(_heap_start <= _heap_end, "PSRAM overflow")
    ASSERT(_stack_bottom < _stack_pointer, "SRAM stack is empty")
    ASSERT(LOADADDR(.data) + SIZEOF(.data)
           <= ORIGIN(flash) + LENGTH(flash),
           "Flash image overflow")
}
