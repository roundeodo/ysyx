#!/usr/bin/env python3
"""Native SoC test-only cross-check; keep it separate from fixed-ns experiments."""
import hashlib
import json
import subprocess
import sys

from run_btb_matrix import NPC, ROOT


def main():
    target = ['--btb-entries', '32', '--btb-ways', '4', '--btb-policy', '2',
              '--btb-index', '2', '--btb-admission', '2']
    configs = {'BT0': [], 'BT32-fold': target,
               'NSL-BT32-fold': [*target, '--direction-policy', '5',
                                 '--branch-sc', '1', '--branch-loop', '1']}
    records = []
    for name, options in configs.items():
        out = ROOT/f'native-btb-{name}-700'
        command = [sys.executable, str(NPC/'scripts/run_microbench_perf.py'),
                   '--scale', 'test', '--cpu-mhz', '700', '--host-opt', '1',
                   '--icache-bytes', '1024', '--icache-ways', '4', '--icache-line', '32',
                   '--icache-policy', '13', '--keep-artifacts', '--output', str(out), *options]
        if not (out/'report.json').exists():
            with (ROOT/f'native-btb-{name}-700.driver.log').open('x') as log:
                subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
        records.append({'name': name, 'command': command, 'report': str(out/'report.json'),
                        'report_sha256': hashlib.sha256((out/'report.json').read_bytes()).hexdigest()})
        (NPC/'docs/research/branch-v3/btb-native-index.json').write_text(
            json.dumps(records, indent=2)+'\n')
        print('PASS native SoC test', name, flush=True)


if __name__ == '__main__':
    main()
