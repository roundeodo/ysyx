ENTRY(_start)

MEMORY {
    flash (rx)  : ORIGIN = 0x30000000, LENGTH = 16M
    sram  (rwx) : ORIGIN = 0x0f000000, LENGTH = 8K
    psram (rwx) : ORIGIN = 0x80000000, LENGTH = 4M
}

SECTIONS {
    /* Only the reset-time image loader executes directly from Flash. */
    .boot : ALIGN(4) {
        KEEP(*(entry))
    } > flash

    /*
     * These sections execute from PSRAM (VMA), while objcopy stores their
     * initial contents directly after .boot in the Flash image (LMA).
     */
    .text : ALIGN(4) {
        _psram_image_start = .;
        *(.text*)
    } > psram AT> flash

    .rodata ALIGN(4) : AT(LOADADDR(.text) + (ADDR(.rodata) - ADDR(.text))) {
        *(.rodata*)
        *(.srodata*)
    } > psram

    .data ALIGN(4) : AT(LOADADDR(.text) + (ADDR(.data) - ADDR(.text))) {
        *(.data*)
        *(.sdata*)
        . = ALIGN(4);
        _psram_image_end = .;
    } > psram

    _psram_image_load_start = LOADADDR(.text);
    _psram_image_load_end   = LOADADDR(.data) + SIZEOF(.data);

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

    ASSERT((_psram_image_end - _psram_image_start)
           == (_psram_image_load_end - _psram_image_load_start),
           "PSRAM image VMA/LMA size mismatch")
    ASSERT(_heap_start <= _heap_end,
           "PSRAM image, BSS and heap exceed 4 MiB")
    ASSERT(_stack_bottom < _stack_pointer,
           "SRAM stack is empty")
    ASSERT(_psram_image_load_end <= ORIGIN(flash) + LENGTH(flash),
           "Flash image overflow")
}
