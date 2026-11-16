#!/usr/bin/env python3
"""Use the same mapping, timing constraints and frequency grid as I-cache selection."""
import argparse
import fcntl
import json
from pathlib import Path

from explore_branch import defines
from select_icache_ppa import qualify


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--configs', nargs='+', required=True)
    parser.add_argument('--resume', action='store_true')
    parser.add_argument('--source-root', type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    configs = json.loads((root / 'configurations.json').read_text())
    (root / 'ppa').mkdir(exist_ok=True)
    for name in args.configs:
        overrides = [setting.replace('YSYX_', 'NPC_', 1) for setting in defines(configs[name])]
        # --resume must never rename a directory owned by another active run.
        with (root / 'ppa' / ('.' + name + '.lock')).open('a') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise RuntimeError(f'Another PPA writer is active for {name}') from error
            qualify(name, root / 'ppa', args.resume, cache_config=(1024, 4, 13, 32), extra_make=overrides,
                    source_root=args.source_root.resolve() if args.source_root else None)


if __name__ == '__main__':
    main()
