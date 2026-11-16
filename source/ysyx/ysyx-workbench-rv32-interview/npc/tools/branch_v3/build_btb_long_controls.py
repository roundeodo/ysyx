#!/usr/bin/env python3
"""Increase only testbench RAM for long inputs; prove short-window equivalence."""
import json
import subprocess
import sys

from run_btb_matrix import NPC, ROOT, TOOL
from summarize_btb import load


CONTROLS = {
    'BT32-fold-long': ('BT32-select-fold', ['--btb', '32', '--btb-ways', '4',
                                          '--btb-index', '2', '--btb-policy', '2',
                                          '--btb-admission', '2']),
    'H2E-victim-long': ('H2E-victim', ['--choice', '2', '--early', '1']),
    'R0-victim-long': ('R0-victim', ['--early-ras', '1']),
}


def main():
    records = []
    for name, (reference, options) in CONTROLS.items():
        if not (ROOT/'builds'/name/'obj/Vexploration_core_tb').exists():
            subprocess.run([sys.executable, str(TOOL/'run_core.py'), 'build',
                            '--name', name, '--ram-kib', '2048', *options], check=True)
        for suffix, images in [('dev', 'images'), ('streams', 'streams-development')]:
            if not (ROOT/'rtl'/f'{name}-{suffix}'/'index.json').exists():
                subprocess.run([sys.executable, str(TOOL/'run_core.py'), 'run',
                                '--name', name, '--label', f'{name}-{suffix}',
                                '--images', str(ROOT/images), '--compact'], check=True)
            ref_suffix = 'stream-dev-700' if reference.endswith('-victim') and suffix == 'streams' else suffix
            candidate, baseline = load(name, suffix), load(reference, ref_suffix)
            assert set(candidate) == set(baseline)
            for case in candidate:
                assert candidate[case]['values'] == baseline[case]['values'], (name, case)
                records.append({'candidate': name, 'reference': reference, 'case': case,
                                'all_RESULT_COUNTERS_DETAIL_equal': True})
        print('PASS RAM-only control', name, flush=True)
    (NPC/'docs/research/branch-v3/btb-long-control-equivalence.json').write_text(
        json.dumps(records, indent=2)+'\n')


if __name__ == '__main__':
    main()
