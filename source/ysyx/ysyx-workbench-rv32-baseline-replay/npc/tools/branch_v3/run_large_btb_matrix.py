#!/usr/bin/env python3
"""Long real request inputs at measured legal clocks; four simulation workers."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import subprocess
import sys

from run_btb_matrix import NPC, ROOT, TOOL

POINTS = {
    'BT0-long': ('BT0', 735),
    'BT16-admit-long': ('BT16-admit', 730),
    'BT16-rrip-all-long': ('BT16-rrip-all', 740),
    'H2E-victim-long': ('H2E-victim', 700),
    'BT32-fold-long': ('BT32-select-fold', 720),
    'NSL-BT32-fold': ('NSL-BT32-fold', 720),
    'NSL-BT64': ('NSL-BT64', 715),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--split', choices=['development', 'validation'], default='development')
    parser.add_argument('--names', nargs='+', choices=POINTS)
    args = parser.parse_args()
    contract = NPC/'docs/research/branch-v3/btb-long-qualification-contract.json'
    record = {'points': POINTS, 'input_scales': [128],
              'weights': 'jsmn/miniz equal; cold/warm equal within family, reported separately from short proxy score',
              'selection': 'current development cost/time candidates, including earlier strong simple control; no new parameter search',
              'validation_input_ranges': [17408, 26112],
              'final_not_used': True}
    # JSON normalizes tuples to arrays.
    serialized = json.dumps(record, indent=2)+'\n'
    if contract.exists():
        assert json.loads(contract.read_text()) == json.loads(serialized)
    else:
        contract.write_text(serialized)

    def measure(item):
        name, (ppa, mhz) = item
        probe = ROOT/'ppa'/ppa/f'probe-{mhz}.json'
        subprocess.run([sys.executable, str(TOOL/'probe_ppa.py'), ppa, '--mhz', str(mhz)],
                       stdout=subprocess.DEVNULL, check=True)
        assert json.loads(probe.read_text())['passed']
        log = ROOT/f'{name}-long-{args.split}-{mhz}.driver.log'
        with log.open('a') as stream:
            subprocess.run([sys.executable, str(TOOL/'run_paired_long.py'), name,
                            '--mhz', str(mhz), '--split', args.split],
                           stdout=stream, stderr=subprocess.STDOUT, check=True)
        print('PASS long legal frequency', args.split, name, mhz, flush=True)

    with ThreadPoolExecutor(max_workers=4) as pool:
        points = POINTS.items() if not args.names else [(name, POINTS[name]) for name in args.names]
        list(pool.map(measure, points))


if __name__ == '__main__':
    main()
