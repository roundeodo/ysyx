ENTRY(_start)
SECTIONS {
  . = 0x80000000;
  .text : { *(.text.start) *(.text*) }
  .rodata : { *(.rodata*) }
  .data : { *(.data*) *(.sdata*) }
  .bss : { *(.bss*) *(.sbss*) *(COMMON) }
  . = ALIGN(16);
  _image_end = .;
  _stack_top = 0x80020000;
  ASSERT(_image_end < 0x80018000, "proxy image overlaps stack")
}
