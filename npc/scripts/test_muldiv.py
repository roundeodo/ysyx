#!/usr/bin/env python3
"""Reproducible RV32 M arithmetic/EXU protocol tests, with Python integer oracle."""
import argparse
import hashlib
import itertools
import json
import random
import subprocess
from pathlib import Path

NPC = Path(__file__).resolve().parents[1]
MASK = (1 << 32) - 1
OPS = ['mul', 'mulh', 'mulhsu', 'mulhu', 'div', 'divu', 'rem', 'remu']


def signed(x):
    return x - (1 << 32) if x >> 31 else x


def oracle(op, a, b):
    if op < 4:
        product = (signed(a) if op in [1, 2] else a) * (signed(b) if op == 1 else b)
        return (product if op == 0 else product >> 32) & MASK
    x, y = (signed(a), signed(b)) if op in [4, 6] else (a, b)
    if not y:
        return MASK if op < 6 else a
    quotient = abs(x) // abs(y)
    if (x < 0) != (y < 0):
        quotient = -quotient
    return (quotient if op < 6 else x - quotient * y) & MASK


def latency(op, a, b):
    if op < 4:
        return 1 if not a or not b else (3 if op == 0 else 4)
    x, y = (abs(signed(a)), abs(signed(b))) if op in [4, 6] else (a, b)
    return 1 if not y or x < y or y == 1 else 34


def vectors():
    rng = random.Random(0x32_20260927)
    corners = [0, 1, 2, 3, 0xffff, 0x10000, 0x10001, 0x7fffffff,
               0x80000000, 0x80000001, 0xffff0000, 0xfffffffe, MASK]
    result = []
    for op in range(8):
        pairs = list(itertools.product(corners, repeat=2))
        pairs += [(rng.getrandbits(32), rng.getrandbits(32)) for _ in range(1200)]
        pairs += [(rng.getrandbits(32), 1 << i) for i in range(32)]
        for a, b in pairs:
            result.append((op, a, b, oracle(op, a, b), latency(op, a, b), -1))
        for cycle in range(1, 35):
            a, b = 0x87654321, 0x1234
            if cycle <= latency(op, a, b):
                result.append((op, a, b, oracle(op, a, b), latency(op, a, b), cycle))
    return result


def run(command, log):
    with log.open('w') as stream:
        subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    cases = vectors()
    vector_file = output / 'vectors.txt'
    vector_file.write_text(''.join(f'{op} {a:08x} {b:08x} {v:08x} {cycles} {abort}\n'
                                  for op, a, b, v, cycles, abort in cases))
    rtl = NPC / 'vsrc/riscv32'
    sources = [rtl / 'common' / name for name in
               ['riscv_config_pkg.sv', 'riscv32_addr_map_pkg.sv', 'riscv32_pkg.sv']]
    sources += [rtl / name for name in ['core/decode/riscv32_idu.sv',
                'core/execute/riscv32_muldiv.sv', 'core/execute/riscv32_div.sv',
                'core/execute/riscv32_mul.sv', 'core/execute/riscv32_exu.sv']]
    sources += [NPC / 'tests/muldiv/riscv32_muldiv_tb.sv']
    records = []
    for enabled in [0, 1]:
        obj = output / f'obj-{enabled}'
        flags = subprocess.check_output(['make', '-s', '-C', str(NPC),
            'NPC_CONFIG=rv32im-balanced', f'NPC_MULDIV_ENABLE={enabled}',
            '--eval=muldiv-flags:;@echo $(NPC_CONFIG_DEFINE)', 'muldiv-flags'], text=True).split()
        command = ['verilator', '--binary', '--timing', '--assert', '-Wno-fatal', '-j', '2',
                   *flags,
                   '--top-module', 'riscv32_muldiv_tb', '--Mdir', str(obj), *map(str, sources)]
        run(command, output / f'build-{enabled}.log')
        run([str(obj / 'Vriscv32_muldiv_tb'), f'+vectors={vector_file}'], output / f'run-{enabled}.log')
        print((output / f'run-{enabled}.log').read_text().strip(), flush=True)
        records.append({'m_enabled': enabled, 'build_command': command, 'passed': True})
    (output / 'report.json').write_text(json.dumps({'vectors': len(cases), 'records': records,
        'sources': {str(p.relative_to(NPC)): hashlib.sha256(p.read_bytes()).hexdigest()
                    for p in sources}}, indent=2) + '\n')


if __name__ == '__main__':
    main()
