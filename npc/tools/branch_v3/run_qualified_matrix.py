#!/usr/bin/env python3
"""Complete paired legal-frequency data for qualified candidates, preserving all runs."""
import argparse
import json
import subprocess
from pathlib import Path
from summarize import PPA

NPC = Path(__file__).resolve().parents[2]
ROOT = NPC/'result/branch-v3'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('names', nargs='+', choices=PPA)
    parser.add_argument('--common-mhz', type=int, default=520)
    args = parser.parse_args()
    for name in args.names:
        path = ROOT/'ppa'/name/'qualified-fine.json'
        if not path.exists():
            path = path.with_name('qualified.json')
        qualified = json.loads(path.read_text())
        assert qualified['all_groups_passed']
        for mhz in sorted({args.common_mhz, qualified['mhz']}):
            assert mhz <= qualified['mhz']
            for dataset, suffix in [('images','proxy'),('real-images-v2','real-v2'),('streams-development','stream')]:
                label = f'{name}-{mhz}MHz-{suffix}'
                index = ROOT/'rtl'/label/'index.json'
                if index.exists():
                    continue
                command = ['python3', str(NPC/'tools/branch_v3/run_core.py'), 'run', '--name', PPA[name],
                           '--label', label, '--mhz', str(mhz), '--images', str(ROOT/dataset)]
                with (ROOT/(label+'.log')).open('x') as stream:
                    subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT, check=True)
                print('PASS paired legal', label, flush=True)


if __name__ == '__main__':
    main()
