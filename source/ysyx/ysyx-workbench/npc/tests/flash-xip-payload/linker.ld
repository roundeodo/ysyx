ENTRY(flash_entry)

MEMORY
{
  flash (rx) : ORIGIN = 0x30000000, LENGTH = 16M
}

SECTIONS
{
  . = ORIGIN(flash);

  .text : ALIGN(4)
  {
    KEEP(*(.text.flash_entry))
    *(.text*)
  } > flash

  .rodata : ALIGN(4)
  {
    *(.rodata*)
  } > flash

  /DISCARD/ :
  {
    *(.comment)
    *(.eh_frame*)
    *(.riscv.attributes)
  }

  ASSERT(SIZEOF(.text) + SIZEOF(.rodata) <= LENGTH(flash),
         "Flash XIP payload overflow")
}
