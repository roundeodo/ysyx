#!/usr/bin/env python3
"""Compare short RV64IM workloads on identical full-SoC images with DiffTest."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

NPC = Path(__file__).resolve().parents[2]
AM = NPC.parent / 'abstract-machine'
MASK = (1 << 64) - 1
CASES = {
    'mul_chain': ('mul s1, s1, t1', (3 * pow(7, 1024, 1 << 64)) & MASK),
    'mul_stream': ('mul s1, t0, t1', 21),
    'div_small': ('divu s1, t2, t1', 1763),
    'div_word': ('divuw s1, t3, t1', 4),
    'div_full': ('divu s1, t4, t1', MASK // 7),
    'two_sources': ('divu s2, t4, t1\n  mul s3, t0, t1\n  add s1, s2, s3', MASK // 7 + 21),
    'load_use': ('ld s1, 0(s8)\n  addi s1, s1, 1\n  sd s1, 0(s8)', 1025),
    'alu_chain': ('addi s1, s1, 1', 1027),
    'store_stream': ('sd s1, 0(s8)\n  addi s8, s8, 8\n  addi s1, s1, 1', 1027),
    'byte_store_stream': ('sb s1, 0(s8)\n  addi s8, s8, 1\n  addi s1, s1, 1', 1027),
}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--current', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--cases', nargs='+', choices=CASES, default=list(CASES))
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    reference = NPC.parent / 'nemu/build/riscv64-nemu-interpreter-so'
    record = {'environment': 'full ysyxSoC, Flash boot, SDRAM execution, DiffTest',
              'window': 'whole program including identical startup', 'cases': [],
              'simulators': {key: {'path': str(path.resolve()), 'sha256': digest(path)}
                             for key, path in [('baseline', args.baseline), ('current', args.current)]},
              'reference_sha256': digest(reference), 'runner_sha256': digest(Path(__file__))}
    for name in args.cases:
        body, expected = CASES[name]
        source, elf, binary = [out / (name + suffix) for suffix in ('.S', '.elf', '.bin')]
        scratch_storage = '.section .bss\n.balign 8\n.space 8192' if name.endswith('store_stream') else ''
        source.write_text(f'''.option norvc
.option norelax
.section .text
.globl _trm_init
_trm_init:
  li s0, 128
  li s1, 3
  li t0, 3
  li t1, 7
  li t2, 12345
  li t3, 0x123456780000001f
  li t4, -1
  la s8, scratch
loop:
.rept 8
  {body}
.endr
  addi s0, s0, -1
  bnez s0, loop
  li t5, 0x{expected:016x}
  bne s1, t5, fail
  li a0, 0
  ebreak
fail:
  li a0, 1
  ebreak
.section .data
.balign 8
scratch: .quad 1
{scratch_storage}
''')
        command = ['riscv64-linux-gnu-gcc', '-march=rv64im_zicsr_zifencei', '-mabi=lp64',
                   '-fno-pic', '-mcmodel=medany', '-nostdlib', '-static',
                   '-Wl,--no-relax,--build-id=none', '-T', str(AM / 'scripts/ysyxsoc-sdram.ld'),
                   '-o', str(elf), str(source), str(AM / 'am/src/riscv/ysyxsoc/start-sdram.S')]
        subprocess.run(command, check=True)
        subprocess.run(['riscv64-linux-gnu-objcopy', '-O', 'binary', str(elf), str(binary)], check=True)
        case = {'name': name, 'build_command': command, 'binary_sha256': digest(binary)}
        case['run_commands'] = {}
        for label, simulator in [('baseline', args.baseline), ('current', args.current)]:
            command = [str(simulator.resolve()), '--batch', '--diff', str(reference), '--flash', str(binary)]
            case['run_commands'][label] = command
            log_path = out / f'{name}-{label}.log'
            with log_path.open('w') as log:
                run = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=300)
            log = log_path.read_text()
            if run.returncode or 'HIT GOOD TRAP' not in log:
                raise RuntimeError(f'Failed {log_path}')
            cycles = int(re.search(r'CPU cycle\s*=\s*(\d+)', log)[1])
            retired = int(re.search(r'retired instructions\s*=\s*(\d+)', log)[1])
            case[label] = {'cycles': cycles, 'retired': retired, 'ipc': retired / cycles}
        if case['baseline']['retired'] != case['current']['retired']:
            raise RuntimeError(f'Retired count changed: {name}')
        case['cycle_reduction_percent'] = 100 * (1 - case['current']['cycles'] / case['baseline']['cycles'])
        record['cases'].append(case)
        (out / 'report.json').write_text(json.dumps(record, indent=2) + '\n')
        print(f"{name}: {case['baseline']['cycles']} -> {case['current']['cycles']} "
              f"({case['cycle_reduction_percent']:+.2f}% fewer cycles)", flush=True)


if __name__ == '__main__':
    main()
