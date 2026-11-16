#!/usr/bin/env python3
"""Run a declared I-cache shortlist; preserve builds, commands and raw results."""
import argparse
import fcntl
import json
import time
from pathlib import Path
from types import SimpleNamespace

import explore_frontend as experiment

# Capacity/ways/policy/line. Chosen from development traces, before held timing.
CONFIGS = {
    'B0': (256, 1, 0, 16),
    'line32': (256, 1, 0, 32),
    'capacity': (512, 1, 0, 16),
    'c256f32': (256, 4, 0, 32),
    'c512d32': (512, 1, 0, 32),
    'c512l32': (512, 2, 4, 32),
    'c512l64': (512, 2, 4, 64),
    'c512b32': (512, 2, 9, 32),
    'c1d32': (1024, 1, 0, 32),
    'c1l32': (1024, 2, 4, 32),
    'c1p16': (1024, 4, 5, 16),
    'c1p32': (1024, 4, 5, 32),
    'c1f32': (1024, 4, 0, 32),
    'c1legacy32': (1024, 4, 1, 32),
    'c1s32': (1024, 4, 12, 32),
    'c1br32': (1024, 4, 7, 32),
    'c1b32': (1024, 4, 9, 32),
    'c1bypass32': (1024, 4, 13, 32),
    'c1sbypass32': (1024, 4, 14, 32),
    'c1h32': (1024, 4, 11, 32),
    'c1hq32': (1024, 4, 15, 32),
    'c1p8': (1024, 8, 5, 32),
    'c1b8': (1024, 8, 9, 32),
    'c2l32': (2048, 2, 4, 32),
    'c2p32': (2048, 4, 5, 32),
    'c2b32': (2048, 4, 9, 32),
    'c2p64': (2048, 4, 5, 64),
    'c2pc64': (2048, 4, 10, 64),
    'c2pcq64': (2048, 4, 16, 64),
    'c4l64': (4096, 2, 4, 64),
}

MODERN_POLICIES = {9, 10, 11, 13, 15, 16}


def defines(config):
    return [f'YSYX_ICACHE_{key}={value}' for key, value in zip(
        ['CAPACITY_BYTES', 'WAY_COUNT', 'REPLACEMENT_POLICY', 'LINE_BYTES'], config)]


def prepare_build(root, name, host_opt, resume=False):
    build = root / ('builds' if host_opt == 0 else f'builds-o{host_opt}') / name
    locks = root / 'build-locks'
    locks.mkdir(parents=True, exist_ok=True)
    # A warm-up build and a subsequent matrix run may reach the same directory.
    # Never archive or consume another live compiler's partial output.
    with (locks / (build.parent.name + '-' + name + '.lock')).open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        binary = build / 'obj/Vexploration_core_tb'
        if build.exists() and not binary.is_file():
            if not resume:
                raise RuntimeError(f'Incomplete build; use --resume: {build}')
            archived = root / 'interrupted' / build.parent.name / (name + '-' + time.strftime('%Y%m%dT%H%M%S'))
            archived.parent.mkdir(parents=True, exist_ok=True)
            build.rename(archived)
        if not build.exists():
            print('BUILD', name, flush=True)
            experiment.build_rtl(build, experiment.NPC / 'vsrc/riscv32', defines(CONFIGS[name]), host_opt)
    return binary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--images', type=Path, required=True)
    parser.add_argument('--configs', nargs='+', choices=CONFIGS, default=list(CONFIGS))
    parser.add_argument('--memory-mode', choices=['cycle', 'physical'], default='physical')
    parser.add_argument('--mhz', type=int, default=580)
    parser.add_argument('--qualified', action='store_true', help='Use each configuration STA pass point')
    parser.add_argument('--held-out', action='store_true')
    parser.add_argument('--latency-ns', type=int, default=100)
    parser.add_argument('--beat-ns', type=int, default=10)
    parser.add_argument('--random-stalls', action='store_true')
    parser.add_argument('--no-observer', action='store_true')
    parser.add_argument('--no-trace', action='store_true')
    parser.add_argument('--host-opt', type=int, choices=[0, 2], default=0)
    parser.add_argument('--resume', action='store_true', help='Archive interrupted outputs, then rerun')
    parser.add_argument('--run-label', default='dev-580')
    args = parser.parse_args()
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=True)
    images = json.loads((args.images.resolve() / 'manifest.json').read_text())['cases']
    expected_images = {case['name']: case['hashes'] for case in images if case['held'] == args.held_out}
    manifest = root / 'shortlist.json'
    if not manifest.exists():
        manifest.write_text(json.dumps(CONFIGS, indent=2) + '\n')
    for name in args.configs:
        mhz = args.mhz
        if args.qualified:
            mhz = json.loads((root.parent / 'ppa' / name / 'qualified.json').read_text())['mhz']
        target = root / args.run_label / name
        result_path = target / 'results.json'
        if result_path.exists():
            saved = json.loads(result_path.read_text())
            if len(saved['results']) == 6:
                assert saved.get('memory_mode', 'cycle') == args.memory_mode, 'Existing memory model differs'
                assert (saved['mhz'], saved['latency_ns'], saved['beat_ns'], saved['random_stalls']) == (
                    mhz, args.latency_ns, args.beat_ns, args.random_stalls), 'Existing run settings differ'
                assert {row['case']['name']: row['case']['hashes'] for row in saved['results']} == expected_images, \
                    'Existing run software or dev/held split differs'
                observer_option = f'+observer={int(not args.no_observer)}'
                assert all(observer_option in row['command'] for row in saved['results']), \
                    'Existing observer mode differs'
                continue
        binary = prepare_build(root, name, args.host_opt, args.resume)
        target = root / args.run_label / name
        if target.exists():
            path = target / 'results.json'
            completed = json.loads(path.read_text()) if path.exists() else {'results': []}
            if len(completed['results']) == 6:
                continue
            if not args.resume:
                raise RuntimeError(f'Incomplete output; use --resume: {target}')
            archived = root / 'interrupted' / args.run_label / (name + '-' + time.strftime('%Y%m%dT%H%M%S'))
            archived.parent.mkdir(parents=True, exist_ok=True)
            target.rename(archived)
        print('RUN', name, args.run_label, flush=True)
        experiment.simulate(SimpleNamespace(
            output=target, images=args.images.resolve(), binary=binary,
            mhz=mhz, held_out=args.held_out, latency_ns=args.latency_ns,
            beat_ns=args.beat_ns, random_stalls=args.random_stalls, no_observer=args.no_observer,
            no_trace=args.no_trace, memory_mode=args.memory_mode))


if __name__ == '__main__':
    main()
