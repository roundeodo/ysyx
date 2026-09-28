#!/usr/bin/env python3
"""Bound synthesis concurrency to two, each job retains its own frozen inputs."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import subprocess
import time
from compact_target_artifacts import archive_sta


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root', type=Path, required=True)
    p.add_argument('--configs', nargs='+', required=True)
    a = p.parse_args()
    root = a.root.resolve()
    def run(name):
        command = ['python3', 'npc/scripts/explore_target_storage.py', 'ppa', '--root', str(root), '--config', name]
        command.append('--resume')
        log_path = root / ('ppa-' + name + '.log')
        if log_path.exists():
            log_path.rename(log_path.with_name(log_path.name + '.interrupted-' + time.strftime('%H%M%S')))
        with log_path.open('x') as log:
            log.write(json.dumps(command) + '\n')
            log.flush()
            subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
        archive_sta(root / 'ppa' / name)
        print('QUALIFIED', name, flush=True)
    with ThreadPoolExecutor(max_workers=2) as pool:
        list(pool.map(run, a.configs))
    (root / 'ppa-queue-complete.json').write_text(json.dumps({'configs': a.configs}, indent=2) + '\n')


if __name__ == '__main__':
    main()
