ENTRY(_start)

MEMORY
{
  mrom (rx) : ORIGIN = 0x20000000, LENGTH = 4K
}

SECTIONS
{
  . = ORIGIN(mrom);

  .text : ALIGN(4)
  {
    KEEP(*(.text._start))
    *(.text*)
  } > mrom

  .rodata : ALIGN(4)
  {
    *(.rodata*)
  } > mrom

  /DISCARD/ :
  {
    *(.comment)
    *(.eh_frame*)
    *(.riscv.attributes)
  }
}
