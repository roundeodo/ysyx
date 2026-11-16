ENTRY(_start)

MEMORY {
    flash (rx)  : ORIGIN = 0x30000000, LENGTH = 16M
    sram  (rwx) : ORIGIN = 0x0f000000, LENGTH = 8K
    sdram (rwx) : ORIGIN = 0xa0000000, LENGTH = 32M
}

SECTIONS {
    /* Reset-time image loader executes directly from Flash. */
    .boot : ALIGN(4) {
        KEEP(*(entry))
    } > flash

    /* Runtime image executes from SDRAM and is initialized from Flash. */
    .text : ALIGN(4) {
        _sdram_image_start = .;
        *(.text*)
    } > sdram AT> flash

    .rodata ALIGN(4) : AT(LOADADDR(.text) + (ADDR(.rodata) - ADDR(.text))) {
        *(.rodata*)
        *(.srodata*)
    } > sdram

    .data ALIGN(4) : AT(LOADADDR(.text) + (ADDR(.data) - ADDR(.text))) {
        *(.data*)
        *(.sdata*)
        . = ALIGN(4);
        _sdram_image_end = .;
    } > sdram

    _sdram_image_load_start = LOADADDR(.text);
    _sdram_image_load_end   = LOADADDR(.data) + SIZEOF(.data);

    .bss (NOLOAD) : ALIGN(4) {
        _bss_start = .;
        *(.bss*)
        *(.sbss*)
        *(COMMON)
        . = ALIGN(4);
        _bss_end = .;
    } > sdram

    _heap_start    = ALIGN(16);
    _heap_end      = ORIGIN(sdram) + LENGTH(sdram);

    _stack_bottom  = ORIGIN(sram);
    _stack_pointer = ORIGIN(sram) + LENGTH(sram);

    ASSERT((_sdram_image_end - _sdram_image_start)
           == (_sdram_image_load_end - _sdram_image_load_start),
           "SDRAM image VMA/LMA size mismatch")
    ASSERT(_heap_start <= _heap_end,
           "SDRAM image, BSS and heap exceed 32 MiB")
    ASSERT(_stack_bottom < _stack_pointer,
           "SRAM stack is empty")
    ASSERT(_sdram_image_load_end <= ORIGIN(flash) + LENGTH(flash),
           "Flash image overflow")
}
