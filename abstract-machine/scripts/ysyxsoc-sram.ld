ENTRY(_start)

MEMORY {
    flash (rx)  : ORIGIN = 0x30000000, LENGTH = 16M
    sram  (rwx) : ORIGIN = 0x0f000000, LENGTH = 8K
}

SRAM_STACK_SIZE = 1K;

SECTIONS {
    /* Reset code executes from Flash and copies the test image into SRAM. */
    .boot : ALIGN(4) {
        KEEP(*(entry))
    } > flash

    .text : ALIGN(4) {
        _sram_image_start = .;
        *(.text*)
    } > sram AT> flash

    .rodata : ALIGN(4) {
        *(.rodata*)
        *(.srodata*)
    } > sram AT> flash

    .data : ALIGN(4) {
        _data_start = .;
        *(.data*)
        *(.sdata*)
        . = ALIGN(4);
        _data_end = .;
        _sram_image_end = .;
    } > sram AT> flash

    _sram_image_load_start = LOADADDR(.text);
    _sram_image_load_end   = LOADADDR(.data) + SIZEOF(.data);

    .bss (NOLOAD) : ALIGN(4) {
        _bss_start = .;
        *(.bss*)
        *(.sbss*)
        *(COMMON)
        . = ALIGN(4);
        _bss_end = .;
    } > sram

    _heap_start    = ALIGN(16);
    _stack_bottom  = ORIGIN(sram) + LENGTH(sram) - SRAM_STACK_SIZE;
    _heap_end      = _stack_bottom;
    _stack_pointer = ORIGIN(sram) + LENGTH(sram);

    ASSERT((_sram_image_end - _sram_image_start)
           == (_sram_image_load_end - _sram_image_load_start),
           "SRAM image VMA/LMA size mismatch")
    ASSERT(_heap_start <= _stack_bottom,
           "SRAM image, BSS, heap and stack exceed 8 KiB")
    ASSERT(_sram_image_load_end <= ORIGIN(flash) + LENGTH(flash),
           "Flash image overflow")
}
