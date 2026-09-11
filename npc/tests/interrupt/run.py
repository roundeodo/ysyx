#!/usr/bin/env python3
"""Run RV32 timer RTL and AM regressions; preserve all build/run logs."""
import os
import sys
from pathlib import Path
import subprocess

NPC = Path(__file__).resolve().parents[2]
TEST = Path(__file__).resolve().parent
AM = NPC.parent / 'abstract-machine'
BUILD = NPC / 'build/tests/interrupt'
BUILD.mkdir(parents=True, exist_ok=True)
if not sys.argv[1:]:
    raise SystemExit('Run make NPC_CONFIG=rv32-baseline test-timer-interrupt to supply configuration')
ENV = dict(os.environ, NPC_HOME=str(NPC))


def run(args, log=None):
    print('+', ' '.join(map(str, args)), flush=True)
    if log is None:
        subprocess.run(list(map(str, args)), env=ENV, cwd=NPC, check=True, timeout=300)
        return
    with log.open('w') as output:
        result = subprocess.run(list(map(str, args)), env=ENV, cwd=NPC,
                                stdout=output, stderr=subprocess.STDOUT, timeout=300)
    if result.returncode:
        print(log.read_text()[-12000:])
        raise SystemExit(result.returncode)
    for line in log.read_text().splitlines():
        if line.startswith('PASS '):
            print(line)


def build_image(name, sources, extra_flags=()):
    run(['riscv64-linux-gnu-gcc', '-march=rv32i_zicsr_zifencei', '-mabi=ilp32',
         '-nostdlib', '-static', '-fno-pic', '-fno-pie', '-mcmodel=medany',
         '-ffreestanding', '-fno-builtin', '-fno-stack-protector',
         '-ffunction-sections', '-fdata-sections', '-msmall-data-limit=0',
         '-O2', '-Wall', '-Werror',
         '-Wl,--no-relax,--build-id=none,--gc-sections,-e,_start',
         f'-Wl,-T,{BUILD / "test.ld"}', *extra_flags, *sources,
         '-o', BUILD / f'{name}.elf'], BUILD / f'{name}_build.log')
    run(['riscv64-linux-gnu-objcopy', '-O', 'binary',
         BUILD / f'{name}.elf', BUILD / f'{name}.bin'])
    data = (BUILD / f'{name}.bin').read_bytes()
    data += bytes((-len(data)) % 4)
    image = BUILD / f'{name}.hex'
    image.write_text(''.join(f'{int.from_bytes(data[i:i+4], "little"):08x}\n'
                             for i in range(0, len(data), 4)))
    return image


def build_testbench(name, directory):
    run(['verilator', '--binary', '--timing', '--assert', '-Wno-fatal', '-j', '2',
         '--top-module', name, '--Mdir', BUILD / directory,
         *sys.argv[1:], '-f', NPC / 'vsrc/riscv32/filelist/filelist.f', TEST / f'{name}.sv'],
        BUILD / f'{directory}_build.log')
    return BUILD / directory / f'V{name}'


(BUILD / 'test.ld').write_text('''ENTRY(_start)
SECTIONS {
  . = 0x80000000;
  .text : { *(.text.start) *(.text .text.*) }
  .rodata : { *(.rodata .rodata.*) }
  .data : { *(.data .data.*) *(.sdata .sdata.*) }
  .bss : { *(.bss .bss.*) *(.sbss .sbss.*) *(COMMON) }
  ASSERT(. < 0x80010000, "test image overlaps scratch memory")
}
''')
assembly_image = build_image('timer_interrupt', [TEST / 'timer_interrupt.S'])
am_image = build_image('am_timer', [TEST / 'am_start.S', TEST / 'am_timer.c',
                                   AM / 'am/src/riscv/npc/cte.c',
                                   AM / 'am/src/riscv/npc/trap.S'],
                       ['-DARCH_H="arch/riscv.h"', f'-I{AM / "am/include"}',
                        f'-I{AM / "am/src"}', f'-I{AM / "klib/include"}'])
system_binary = build_testbench('riscv32_timer_system_tb', 'system_obj')
for delay in (0, 17, 83):
    run([system_binary, f'+image={assembly_image}', f'+delay={delay}'],
        BUILD / f'system_delay_{delay}.log')
for delay in (0, 83):
    run([system_binary, f'+image={am_image}', f'+delay={delay}', '+am=1'],
        BUILD / f'am_delay_{delay}.log')
for name, directory in [('riscv32_clint_tb', 'clint_obj'),
                        ('riscv32_interrupt_control_tb', 'control_obj'),
                        ('riscv32_ifu_redirect_tb', 'ifu_obj')]:
    binary = build_testbench(name, directory)
    run([binary], BUILD / f'{name}.log')
print('PASS timer regression: 3 assembly system runs, 2 AM system runs, 3 RTL unit tests')
