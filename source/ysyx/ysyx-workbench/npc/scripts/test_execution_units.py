#!/usr/bin/env python3
"""Check execution RTL against independent integer arithmetic and protocol scoreboards."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import random
import subprocess

NPC = Path(__file__).resolve().parents[1]
MASK = (1 << 64) - 1
EDGES = [0, 1, 2, 3, 31, 32, 63, 64, 0x7fffffff, 0x80000000, 0xffffffff,
         0x100000000, 0x7fffffffffffffff, 0x8000000000000000, MASK,
         0xffffffff80000000, 0x1234567880000001]


def signed(value, width=64):
    value &= (1 << width) - 1
    return value - (1 << width) if value >> (width - 1) else value


def alu_result(op, a, b):
    if op in (0, 10): value = a + b
    elif op in (1, 11): value = a - b
    elif op in (2, 12): value = a << (b & (31 if op == 12 else 63))
    elif op == 3: value = int(signed(a) < signed(b))
    elif op == 4: value = int(a < b)
    elif op == 5: value = a ^ b
    elif op in (6, 13): value = (a & (0xffffffff if op == 13 else MASK)) >> (b & (31 if op == 13 else 63))
    elif op in (7, 14): value = signed(a, 32 if op == 14 else 64) >> (b & (31 if op == 14 else 63))
    elif op == 8: value = a | b
    elif op == 9: value = a & b
    else: value = 0
    return (signed(value, 32) if 10 <= op <= 14 else value) & MASK


def muldiv_result(op, word, a, b):
    if op < 4:
        lhs = signed(a) if op in (1, 2) else a
        rhs = signed(b) if op == 1 else b
        value = lhs * rhs
        if op: value >>= 64
    else:
        width = 32 if word else 64
        mask = (1 << width) - 1
        lhs, rhs = a & mask, b & mask
        if op in (4, 6): lhs, rhs = signed(lhs, width), signed(rhs, width)
        if rhs == 0:
            quotient, remainder = mask, lhs
        else:
            quotient = abs(lhs) // abs(rhs)
            if (lhs < 0) != (rhs < 0): quotient = -quotient
            remainder = lhs - quotient * rhs
        value = quotient if op in (4, 5) else remainder
    return (signed(value, 32) if word else value) & MASK


def write_vectors(output, samples, seed):
    generator = random.Random(seed)
    pairs = [(a, b) for a in EDGES for b in EDGES]
    pairs += [(generator.getrandbits(64), generator.getrandbits(64)) for _ in range(samples)]
    alu = [(op, 0, a, b, alu_result(op, a, b)) for op in range(16) for a, b in pairs]
    modes = [(op, 0) for op in range(8)] + [(op, 1) for op in (0, 4, 5, 6, 7)]
    muldiv = [(op, word, a, b, muldiv_result(op, word, a, b))
              for op, word in modes for a, b in pairs]
    paths = []
    for name, values in [('alu', alu), ('muldiv', muldiv)]:
        path = output / (name + '.vectors')
        path.write_text(''.join(' '.join(format(v, 'x') for v in row) + '\n' for row in values))
        paths.append(path)
    return paths, {'alu': len(alu), 'muldiv': len(muldiv), 'seed': seed, 'samples': samples}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--samples', type=int, default=512)
    parser.add_argument('--seed', type=int, default=20260926)
    parser.add_argument('--jobs', type=int, default=2)
    parser.add_argument('defines', nargs='+')
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    vectors, counts = write_vectors(output, args.samples, args.seed)
    top = 'riscv_execution_units_tb'
    command = ['verilator', '--cc', '--exe', '--build', '--assert', '-Wall', '-Wno-fatal',
               '--top-module', top, '-j', str(args.jobs), '--Mdir', str(output / 'obj'),
               '-CFLAGS', '-O0', '-MAKEFLAGS', 'OPT_FAST=-O0 OPT_SLOW=-O0',
               *args.defines, '-I' + str(NPC / 'vsrc/riscv/sim'),
               '-f', str(NPC / 'vsrc/riscv/filelist/filelist_sta.f'),
               str(NPC / 'tests/rtl' / (top + '.sv')),
               str(NPC / 'tests/rtl/riscv_execution_units_driver.cpp')]
    sources = sorted((NPC / 'vsrc/riscv').rglob('*.sv')) + [
        NPC / 'tests/rtl' / (top + '.sv'), NPC / 'tests/rtl/riscv_execution_units_driver.cpp',
        Path(__file__)]
    record = {'counts': counts, 'command': command,
              'source_hashes': {str(p.relative_to(NPC)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
              'vector_hashes': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in vectors}}
    (output / 'manifest.json').write_text(json.dumps(record, indent=2) + '\n')
    with (output / 'build.log').open('w') as log:
        result = subprocess.run(command, cwd=NPC, env=dict(os.environ, NPC_HOME=str(NPC)),
                                stdout=log, stderr=subprocess.STDOUT, timeout=1800)
    record['build_exit'] = result.returncode
    if result.returncode == 0:
        run = [str(output / 'obj' / ('V' + top)), *map(str, vectors)]
        record['run_command'] = run
        with (output / 'run.log').open('w') as log:
            result = subprocess.run(run, stdout=log, stderr=subprocess.STDOUT, timeout=180)
        record['run_exit'] = result.returncode
        print((output / 'run.log').read_text())
    else:
        print((output / 'build.log').read_text()[-8000:])
    record['passed'] = record['build_exit'] == 0 and record.get('run_exit') == 0
    (output / 'manifest.json').write_text(json.dumps(record, indent=2) + '\n')
    raise SystemExit(0 if record['passed'] else 1)


if __name__ == '__main__':
    main()
