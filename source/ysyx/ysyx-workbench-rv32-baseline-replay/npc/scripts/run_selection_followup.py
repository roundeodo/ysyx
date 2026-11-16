#!/usr/bin/env python3
"""Serialize learned-query checks and remaining host builds after MicroBench."""
import argparse
import json
from pathlib import Path
import subprocess
import time

from explore_frontend import NPC
from select_icache import prepare_build


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    deadline = time.monotonic() + 8 * 3600
    while not (root / 'microbench/c1bypass32-720/report.json').exists():
        if time.monotonic() > deadline:
            raise RuntimeError('MicroBench controls have not completed')
        time.sleep(10)

    def run(script, *arguments):
        subprocess.run(['python3', str(NPC / 'scripts' / (script + '.py')),
                        *map(str, arguments)], check=True)

    run('test_selection_replacement', '--output', root / 'learned-query-tests', '--policies', 15, 16)
    run('select_icache', '--output', root / 'rtl', '--images', root / 'images-v1',
        '--configs', 'c1hq32', 'c2pcq64', '--host-opt', 2, '--no-trace', '--resume')
    records = []
    for original, bypass in [('c1h32', 'c1hq32'), ('c2pc64', 'c2pcq64')]:
        old = json.loads((root / 'rtl/dev-580' / original / 'results.json').read_text())['results']
        new = json.loads((root / 'rtl/dev-580' / bypass / 'results.json').read_text())['results']
        assert len(old) == len(new) == 6
        assert all(a['case'] == b['case'] and a['result'] == b['result'] and
                   a['counters'] == b['counters'] for a, b in zip(old, new)), bypass
        records.append({'original': original, 'query_bypass': bypass, 'cases': 6,
                        'results_and_counters_equal': True, 'clock': 'logical 580 MHz; no STA claim'})
    (root / 'learned-query-equivalence.json').write_text(json.dumps(records, indent=2) + '\n')
    run('verify_icache_selection', '--output', root / 'learned-query-safety',
        '--configs', 'c1hq32', 'c2pcq64', '--full')
    (root / 'learned-query-validation.json').write_text(json.dumps({'status': 'passed'}, indent=2) + '\n')
    for name in ['line32', 'capacity', 'c512d32', 'c1d32', 'c1l32', 'c1p32', 'c1b32']:
        prepare_build(root / 'rtl', name, 2, resume=True)
    print('FOLLOWUP CHECKS AND WARM BUILDS COMPLETE', flush=True)


if __name__ == '__main__':
    main()
