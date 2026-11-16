#!/usr/bin/env python3
"""Attribute direction-model errors to software functions on development inputs."""
import argparse
from bisect import bisect_right
from collections import Counter
import hashlib
import json
from pathlib import Path
import subprocess

from model_branch import decode, evaluate
from model_direction import CounterTable, BiMode, LoopTable


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = {'scope': 'development-only resolved-order model, full-PC error attribution', 'cases': {}}
    previous = json.loads((args.root / 'direction-model-v1/results.json').read_text())
    for case in json.loads((args.root / 'images/manifest.json').read_text())['cases']:
        if case['held']:
            continue
        trace = args.root / 'rtl/dev-720/B0' / (case['name'] + '.trace')
        raw = trace.read_bytes()
        assert hashlib.sha256(raw).hexdigest() == previous['traces'][case['name']]
        records, instructions = [], 0
        for line in raw.decode().splitlines():
            pc, insn, nxt, cycle = line.split(',')
            record = decode(int(pc, 16), int(insn, 16), int(nxt, 16))
            instructions += 1
            if record:
                records.append(record)
        symbols = []
        command = ['riscv64-linux-gnu-nm', '-n', str(args.root / 'images' / case['name'] / 'image.elf')]
        for line in subprocess.check_output(command, text=True).splitlines():
            fields = line.split()
            if len(fields) == 3 and fields[1] in ('t', 'T'):
                symbols.append((int(fields[0], 16), fields[2]))
        addresses = [pc for pc, name in symbols]
        rows = {}
        for name, direction in [('bimodal-64', CounterTable(64)),
                                ('bimode-64-h4', BiMode(64, 4)), ('loop-4', LoopTable(4))]:
            result = evaluate(records, instructions, dict(bht=64, btb=16, ways=2, ras=4, policy='taken'),
                              direction, error_pc_limit=None)
            assert result['counts'] == previous['cases'][case['name']]['btb16-' + name]['counts']
            errors = Counter()
            for pc, count in result['hot_error_pc']:
                index = bisect_right(addresses, pc) - 1
                errors[symbols[index][1] if index >= 0 else 'unknown'] += count
            assert sum(errors.values()) == result['counts']['errors']
            rows[name] = dict(errors=errors, total=sum(errors.values()))
        output['cases'][case['name']] = rows
        print('ATTRIBUTED', case['name'], flush=True)
    with args.output.open('x') as stream:
        stream.write(json.dumps(output, indent=2) + '\n')


if __name__ == '__main__':
    main()
