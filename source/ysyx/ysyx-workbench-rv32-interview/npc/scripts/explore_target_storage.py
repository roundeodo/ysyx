#!/usr/bin/env python3
"""Build, simulate or qualify the frozen target-storage configurations."""
import argparse
import json
from pathlib import Path
from types import SimpleNamespace
import explore_frontend as experiment
from followup_branch import defines as base_defines
from select_icache_ppa import qualify


def defines(config):
    values = dict(word.split('=', 1) for word in base_defines({'btb': config['btb']}))
    values['YSYX_BRANCH_TARGET_WAY_COUNT'] = str(config['ways'])
    widths = config.get('widths')
    packed = sum(width << (8 * way) for way, width in enumerate(widths)) if widths else 0
    values['YSYX_BRANCH_TARGET_WAY_BITS'] = str(packed)
    values['YSYX_BRANCH_TARGET_POLICY'] = str(config.get('policy', 0))
    return [key + '=' + value for key, value in values.items()]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('action', choices=['build', 'run', 'ppa'])
    p.add_argument('--root', type=Path, required=True)
    p.add_argument('--config', required=True)
    p.add_argument('--label', default='dev-common')
    p.add_argument('--mhz', type=int, default=720)
    p.add_argument('--images', type=Path)
    p.add_argument('--held', action='store_true')
    p.add_argument('--random-stalls', action='store_true')
    p.add_argument('--latency-ns', type=int, default=100)
    p.add_argument('--beat-ns', type=int, default=10)
    p.add_argument('--trace', action='store_true')
    p.add_argument('--resume', action='store_true')
    a = p.parse_args()
    root = a.root.resolve()
    config = json.loads((root / 'configurations.json').read_text())[a.config]
    source = root / ('baseline' if config.get('source') == 'baseline' else 'candidate-source')
    build = root / 'builds' / a.config
    if a.action == 'build':
        experiment.TEST = source / 'npc/tests/frontend_exploration'
        experiment.build_rtl(build, source / 'npc/vsrc/riscv32', defines(config), host_opt=2)
        (build / 'config.json').write_text(json.dumps(config, indent=2) + '\n')
    elif a.action == 'ppa':
        (root / 'ppa').mkdir(exist_ok=True)
        qualify(a.config, root / 'ppa', a.resume, cache_config=(1024, 4, 13, 32),
                extra_make=[word.replace('YSYX_', 'NPC_', 1) for word in defines(config)], source_root=source)
    else:
        assert json.loads((build / 'config.json').read_text()) == config
        if a.held:
            assert (root / 'selection-freeze.json').exists(), 'Freeze choice before held performance'
        experiment.simulate(SimpleNamespace(
            output=root / 'rtl' / a.label / a.config,
            images=a.images.resolve() if a.images else root / 'images',
            binary=build / 'obj/Vexploration_core_tb', mhz=a.mhz, held_out=a.held,
            latency_ns=a.latency_ns, beat_ns=a.beat_ns, random_stalls=a.random_stalls,
            no_observer=False, no_trace=not a.trace, memory_mode='physical'))


if __name__ == '__main__':
    main()
