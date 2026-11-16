ENTRY(_start)

MEMORY
{
  sram (rwx) : ORIGIN = 0x0f000000, LENGTH = 8K
}

SECTIONS
{
  . = ORIGIN(sram);

  .text : ALIGN(4)
  {
    KEEP(*(.text._start))
    *(.text*)
  } > sram

  .rodata : ALIGN(4)
  {
    *(.rodata*)
  } > sram

  /DISCARD/ :
  {
    *(.comment)
    *(.eh_frame*)
    *(.riscv.attributes)
  }
}
