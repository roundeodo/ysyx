#!/usr/bin/env python3
"""Compare I/IM scalar int8 dot software on one M-enabled core; no CSR instrumentation."""
import argparse
import hashlib
import json
from pathlib import Path
import re
from test_muldiv import NPC, run


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--simulator', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    output = args.output.resolve(); output.mkdir(parents=True, exist_ok=True)
    start = output / 'start.S'
    start.write_text('.section .text.start\n.globl _start\n_start:\n'
                     'li sp,0x800f0000\ncall main\nebreak\n')
    linker = output / 'test.ld'
    linker.write_text('ENTRY(_start)\nSECTIONS { . = 0x80000000; '
                      '.text : { *(.text.start) *(.text .text.*) } '
                      '.rodata : { *(.rodata*) } .data : { *(.data*) *(.sdata*) } '
                      '.bss : { *(.bss*) *(.sbss*) *(COMMON) } }\n')
    def int8(x):
        return ((x + 128) & 255) - 128
    a, b = [[int8(i * scale + offset) for i in range(64)] for scale, offset in [(37,13),(19,11)]]
    checksum = 0
    for round in range(256):
        dot = sum(a[i] * b[(i + round) & 63] for i in range(64))
        quotient = abs(dot) // ((round & 15) + 1)
        if dot < 0:
            quotient = -quotient
        checksum = (((checksum << 5) | (checksum >> 27)) ^ (quotient & 0xffffffff)) & 0xffffffff
    source = NPC / 'tests/muldiv/quantized_dot.c'
    lib = NPC.parent / 'abstract-machine/am/src/riscv/npc/libgcc'
    reference = NPC.parent / 'nemu/build/riscv32-nemu-interpreter-so'
    result = {'workload': 'scalar-int8-dot-normalize', 'checksum': hex(checksum),
              'timing_scope': 'whole standalone NPC program, flat memory; not SoC timer',
              'cpu': 'same RV32IM balanced simulator for both software images', 'records': [],
              'sha256': {str(p): hashlib.sha256(p.read_bytes()).hexdigest()
                         for p in [source, args.simulator, reference, Path(__file__)]}}
    for isa in ['rv32i', 'rv32im']:
        elf, binary = [output / (isa + '.' + ext) for ext in ['elf', 'bin']]
        command = ['riscv64-linux-gnu-gcc', f'-march={isa}_zicsr_zifencei', '-mabi=ilp32',
                   '-nostdlib', '-static', '-fno-pic', '-fno-pie', '-mcmodel=medany',
                   '-ffreestanding', '-fno-builtin', '-msmall-data-limit=0', '-O2',
                   '-ffunction-sections', '-fdata-sections', '-Wl,--no-relax,--build-id=none,--gc-sections',
                   f'-Wl,-T,{linker}', f'-DEXPECTED_CHECKSUM={checksum}u',
                   str(start), str(source), str(lib/'muldi3.S'), str(lib/'div.S'), '-o', str(elf)]
        run(command, output / f'{isa}-build.log')
        run(['riscv64-linux-gnu-objcopy', '-O', 'binary', str(elf), str(binary)], output / f'{isa}-objcopy.log')
        run([str(args.simulator.resolve()), '--batch', '--diff', str(reference), str(binary)],
            output / f'{isa}-run.log')
        text = (output / f'{isa}-run.log').read_text()
        assert 'HIT GOOD TRAP' in text
        cycles = int(re.search(r'CPU cycle\s*=\s*(\d+)', text)[1])
        retired = int(re.search(r'retired instructions\s*=\s*(\d+)', text)[1])
        result['records'].append({'isa': isa, 'cycles': cycles, 'retired': retired,
                                  'ipc': retired/cycles, 'build_command': command,
                                  'image_sha256': hashlib.sha256(binary.read_bytes()).hexdigest()})
        print(isa, cycles, retired, flush=True)
    result['speedup_same_frequency'] = result['records'][0]['cycles']/result['records'][1]['cycles']
    (output / 'report.json').write_text(json.dumps(result, indent=2)+'\n')


if __name__ == '__main__':
    main()
