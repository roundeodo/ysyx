#!/usr/bin/env python3
"""Compare unchanged predictor candidates on two pre-existing code placements."""
from concurrent.futures import ThreadPoolExecutor
import json
import subprocess
import sys

from run_btb_matrix import NPC, ROOT, TOOL
from summarize_btb import paired


def main():
    names = ['BT0', 'H2E-victim', 'BT32-select-fold', 'NSL-BT32-fold']
    layouts = ['3f00', 'ff00']

    def measure(name):
        subprocess.run([sys.executable, str(TOOL/'probe_ppa.py'), name, '--mhz', '520'],
                       stdout=subprocess.DEVNULL, check=True)
        assert json.loads((ROOT/'ppa'/name/'probe-520.json').read_text())['passed']
        for layout in layouts:
            label = f'{name}-btb-layout-{layout}-520'
            if (ROOT/'rtl'/label/'index.json').exists():
                continue
            subprocess.run([sys.executable, str(TOOL/'run_core.py'), 'run', '--name', name,
                            '--label', label, '--images', str(ROOT/'layouts'/layout),
                            '--compact', '--mhz', '520'], check=True)

    with ThreadPoolExecutor(max_workers=2) as pool:
        list(pool.map(measure, names))
    results = []
    for layout in layouts:
        for name in names:
            suffix = [f'btb-layout-{layout}-520']
            results.append({'layout': layout, **paired(name, suffix, 'BT0', suffix)})
    (NPC/'docs/research/branch-v3/btb-layout-results.json').write_text(
        json.dumps({'scope': 'development placement sensitivity, not independent final inputs',
                    'same_legal_mhz': 520, 'results': results}, indent=2)+'\n')


if __name__ == '__main__':
    main()
