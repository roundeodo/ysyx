#!/usr/bin/env python3
"""Build and measure frozen branch configurations without changing the cache preset."""
import argparse
import json
from pathlib import Path
from types import SimpleNamespace

import explore_frontend as experiment


def defines(config):
    settings = {
        'ICACHE_CAPACITY_BYTES': 1024, 'ICACHE_WAY_COUNT': 4,
        'ICACHE_LINE_BYTES': 32, 'ICACHE_REPLACEMENT_POLICY': 13,
        'BRANCH_HISTORY_ENTRY_COUNT': config['bht'],
        'BRANCH_TARGET_ENTRY_COUNT': config['btb'],
        'BRANCH_TARGET_WAY_COUNT': config['ways'],
        'RETURN_STACK_ENTRY_COUNT': config['ras'],
        'BRANCH_TARGET_POLICY': config.get('policy', 0),
    }
    return [f'YSYX_{key}={value}' for key, value in settings.items()]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['build', 'run'])
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--config', required=True)
    parser.add_argument('--source-root', type=Path, default=experiment.NPC.parent)
    parser.add_argument('--mhz', type=int, default=720)
    parser.add_argument('--run-label', default='dev-720')
    parser.add_argument('--held-out', action='store_true')
    parser.add_argument('--trace', action='store_true')
    parser.add_argument('--random-stalls', action='store_true')
    parser.add_argument('--no-observer', action='store_true')
    parser.add_argument('--latency-ns', type=int, default=100)
    parser.add_argument('--beat-ns', type=int, default=10)
    args = parser.parse_args()
    root = args.root.resolve()
    config = json.loads((root / 'configurations.json').read_text())[args.config]
    build = root / 'builds' / args.config
    if args.action == 'build':
        source = args.source_root.resolve() / 'npc'
        experiment.TEST = source / 'tests/frontend_exploration'
        experiment.build_rtl(build, source / 'vsrc/riscv32', defines(config), host_opt=2)
        (build / 'branch-config.json').write_text(json.dumps(config, indent=2) + '\n')
    else:
        assert json.loads((build / 'branch-config.json').read_text()) == config
        experiment.simulate(SimpleNamespace(
            output=root / 'rtl' / args.run_label / args.config,
            images=root / 'images', binary=build / 'obj/Vexploration_core_tb',
            mhz=args.mhz, held_out=args.held_out, latency_ns=args.latency_ns,
            beat_ns=args.beat_ns, random_stalls=args.random_stalls,
            no_observer=args.no_observer, no_trace=not args.trace, memory_mode='physical'))


if __name__ == '__main__':
    main()
