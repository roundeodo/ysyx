#!/usr/bin/env python3
"""Attribute model behavior to real development-program functions, not input names."""
import argparse
from bisect import bisect_right
from collections import Counter
import hashlib
import json
import math
from pathlib import Path
import subprocess
from model_branch import decode, evaluate
from model_direction import CounterTable, BiMode


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root', type=Path, required=True)
    args = p.parse_args()
    root = args.root.resolve()
    previous = json.loads((root / 'model/results.json').read_text())
    config = json.loads((root / 'configurations.json').read_text())
    output = {'scope': 'cold immediate-training model attribution; not RTL cycles', 'cases': {}}
    for case in json.loads((root / 'images/manifest.json').read_text())['cases']:
        if case['held']:
            continue
        raw = (root / 'rtl/dev-common/B0' / (case['name'] + '.trace')).read_bytes()
        assert hashlib.sha256(raw).hexdigest() == previous['traces'][case['name']]
        records, count = [], 0
        for line in raw.decode().splitlines():
            pc, instruction, next_pc, _ = line.split(',')
            decoded = decode(int(pc, 16), int(instruction, 16), int(next_pc, 16))
            count += 1
            if decoded:
                records.append(decoded)
        symbols = []
        for line in subprocess.check_output(['riscv64-linux-gnu-nm', '-n',
                str(root / 'images' / case['name'] / 'image.elf')], text=True).splitlines():
            fields = line.split()
            if len(fields) == 3 and fields[1] in ['t', 'T']:
                symbols.append((int(fields[0], 16), fields[2]))
        addresses = [pc for pc, name in symbols]
        def function(pc):
            index = bisect_right(addresses, pc) - 1
            return symbols[index][1] if index >= 0 else 'unknown'
        row = {'retired': count, 'dynamic_control_flow': len(records),
               'branches_by_function': dict(Counter(function(r[0]) for r in records)),
               'conditional_by_function': dict(Counter(function(r[0]) for r in records if r[1] == 0)),
               'ambiguous_target_pc_plus_four': sum(r[1] == 0 and r[3] == r[0] + 4 for r in records),
               'models': {}}
        for name in ['B0', 'B64', 'B128', 'G64', 'G128', 'M64']:
            c = config[name]
            policy = c.get('direction_policy', 0)
            entries = c['bht']
            direction = (BiMode(entries, 4) if policy == 2 else
                         CounterTable(entries, 4 if policy == 1 else 0,
                                      history_shift=int(math.log2(entries)) - 4 if policy == 1 else 0))
            result = evaluate(records, count, dict(bht=entries, btb=16, ways=2, ras=4, policy='all'),
                              direction, error_pc_limit=None)
            assert result['counts'] == previous['cases'][case['name']]['rows'][name]['counts']
            errors = Counter()
            for pc, total in result['hot_error_pc']:
                errors[function(pc)] += total
            assert sum(errors.values()) == result['counts']['errors']
            row['models'][name] = dict(errors)
        output['cases'][case['name']] = row
        print('PROFILE', case['name'], flush=True)
    with (root / 'model/functions.json').open('x') as stream:
        stream.write(json.dumps(output, indent=2) + '\n')


if __name__ == '__main__':
    main()
