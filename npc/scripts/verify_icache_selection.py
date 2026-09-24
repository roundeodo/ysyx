#!/usr/bin/env python3
"""Exercise the selected cache geometry with existing independent safety suites."""
import argparse
import json
from pathlib import Path

from explore_frontend import NPC, run
from select_icache import CONFIGS


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--configs', nargs='+', choices=CONFIGS, required=True)
    parser.add_argument('--full', action='store_true')
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    records = []
    for name in args.configs:
        folder = out / name
        folder.mkdir()
        capacity, ways, policy, line = CONFIGS[name]
        variables = [f'NPC_ICACHE_CAPACITY_BYTES={capacity}', f'NPC_ICACHE_WAY_COUNT={ways}',
                     f'NPC_ICACHE_REPLACEMENT_POLICY={policy}', f'NPC_ICACHE_LINE_BYTES={line}',
                     f'FRONTEND_TEST_OUTPUT={folder / "frontend"}',
                     f'CACHE_RECOVERY_OUTPUT={folder / "recovery"}',
                     f'EXCEPTION_TEST_OUTPUT={folder / "exception"}']
        goals = ['test-icache']
        if args.full:
            goals += ['test-fence-i', 'test-dcache-recovery', 'test-precise-exception']
        for goal in goals:
            command = ['make', 'git_commit=', 'NPC_CONFIG=rv32-baseline', *variables, goal]
            run(command, folder / (goal + '.log'))
            records.append({'config': name, 'command': command, 'passed': True})
            (out / 'manifest.json').write_text(json.dumps(records, indent=2) + '\n')
            print(name, goal, 'PASS', flush=True)


if __name__ == '__main__':
    main()
