#!/usr/bin/env python3
"""Check M instructions, RAW/rd aliases and precise traps on the whole RV32 core."""
import argparse
import json
import hashlib
from pathlib import Path
from test_muldiv import NPC, OPS, vectors, run


def image(output, name, assembly):
    source = output / (name + '.S')
    source.write_text('.section .text\n.globl _start\n_start:\n' + assembly)
    obj, elf, binary = [output / (name + '.' + ext) for ext in ['o', 'elf', 'bin']]
    commands = [
        ['riscv64-linux-gnu-as', '-march=rv32im_zicsr_zifencei', '-mabi=ilp32', '-o', str(obj), str(source)],
        ['riscv64-linux-gnu-ld', '-m', 'elf32lriscv', '-Ttext=0x80000000', '-o', str(elf), str(obj)],
        ['riscv64-linux-gnu-objcopy', '-O', 'binary', str(elf), str(binary)]]
    for index, command in enumerate(commands):
        run(command, output / f'{name}-build-{index}.log')
    return binary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--simulator', required=True, type=Path)
    args = parser.parse_args()
    output = args.output.resolve(); output.mkdir(parents=True, exist_ok=True)
    # Python integer oracle and independent NEMU both check the same emitted operations.
    assembly = ['li s0,0x800f0000']
    count = 0
    for index, (op, a, b, expected, cycles, abort) in enumerate(vectors()):
        if abort >= 0 or index % 4 != 0:
            continue
        dest = ['t2', 't0', 't1'][count % 3]
        assembly += [f'li t0,0x{a:08x}', f'li t1,0x{b:08x}', 'li t2,0x12345678',
                     f'{OPS[op]} {dest},t0,t1', f'addi t3,{dest},1',
                     f'li t4,0x{(expected+1)&0xffffffff:08x}', 'bne t3,t4,fail',
                     f'sw {dest},0(s0)', 'lw t5,0(s0)', f'li t4,0x{expected:08x}',
                     'bne t5,t4,fail', f'{OPS[op]} zero,t0,t1', 'bnez zero,fail']
        count += 1
    assembly += ['li a0,0', 'ebreak', 'fail:', 'li a0,1', 'ebreak']
    arithmetic = image(output, 'arithmetic', '\n'.join(assembly))
    reference = NPC.parent / 'nemu/build/riscv32-nemu-interpreter-so'
    command = [str(args.simulator.resolve()), '--batch', '--diff', str(reference), str(arithmetic)]
    run(command, output / 'arithmetic-difftest.log')
    assert 'HIT GOOD TRAP' in (output / 'arithmetic-difftest.log').read_text()
    traps = image(output, 'traps', '''
      la t0,handler
      csrw mtvec,t0
      li s0,0x800f0000
      sw zero,0(s0)
      li s1,0
      csrr t0,misa
      andi t0,t0,0x100
      beqz t0,fail
      csrr t0,misa
      srli t0,t0,12
      andi t0,t0,1
      beqz t0,fail
      li t0,0x76543210
      li t1,17
    fault_site:
      .word 0xffffffff
      div t2,t0,t1
      sw t2,0(s0)
      j fail
    resume_site:
      lw t2,0(s0)
      bnez t2,fail
      li t2,1
      bne s1,t2,fail
      div t0,t0,t1
      li t2,0x06f5e4d3
      bne t0,t2,fail
      mul t1,t0,t1
      li t2,0x76543203
      bne t1,t2,fail
      li a0,0
      ebreak
    handler:
      csrr t3,mcause
      li t4,2
      bne t3,t4,fail
      csrr t3,mepc
      la t4,fault_site
      bne t3,t4,fail
      addi s1,s1,1
      la t3,resume_site
      csrw mepc,t3
      mret
    fail:
      li a0,1
      ebreak
    ''')
    command2 = [str(args.simulator.resolve()), '--batch', str(traps)]
    run(command2, output / 'traps.log')
    assert 'HIT GOOD TRAP' in (output / 'traps.log').read_text()
    (output / 'report.json').write_text(json.dumps({'arithmetic_cases': count,
        'difftest': True, 'misa_and_precise_trap': True, 'commands': [command, command2],
        'sha256': {str(p): hashlib.sha256(p.read_bytes()).hexdigest()
                   for p in [args.simulator, reference, arithmetic, traps, Path(__file__)]}}, indent=2)+'\n')
    print(f'PASS {count} whole-core arithmetic/alias cases + precise trap and misa')


if __name__ == '__main__':
    main()
