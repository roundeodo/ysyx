#!/usr/bin/env python3
"""Replay the fixed wait-optimization workloads; preserve compact evidence only."""
import argparse
import fcntl
import json
from pathlib import Path
import shutil
import subprocess
import sys
from types import SimpleNamespace

NPC = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(NPC / 'scripts'))
import explore_frontend as experiment
from followup_branch import defines


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('name')
    parser.add_argument('--source', type=Path, default=NPC / 'vsrc/riscv32')
    parser.add_argument('--random-checks', action='store_true')
    parser.add_argument('--mhz', type=int, default=700)
    args = parser.parse_args()
    assert args.name.replace('-', '').isalnum(), 'Use a simple experiment name'
    archive = NPC / 'docs/verification/data/wait-opt-20261002' / args.name / 'proxy'
    assert not archive.exists(), archive
    root = NPC / 'result/wait-opt-proxy/current'
    root.parent.mkdir(parents=True, exist_ok=True)
    lock = (root.parent / '.lock').open('a')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    if root.exists():
        assert (root / '.npc-generated-workspace').is_file()
        shutil.rmtree(root)
    root.mkdir(parents=True)
    (root / '.npc-generated-workspace').write_text('wait optimization proxy workdir\n')
    source = root / 'rtl'
    shutil.copytree(args.source, source)
    experiment.TEST = NPC / 'tests/branch_v3'
    settings = defines({}) + ['YSYX_BRANCH_STATIC_POLICY=2',
                             'YSYX_BRANCH_EARLY_TARGET=1',
                             'BRANCH_V3_RAM_BYTES=2097152']
    experiment.build_rtl(root / 'build', source, settings, host_opt=2)
    suites = [('dev', 'images', False), ('streams', 'streams-development', False)]
    if args.random_checks:
        suites += [('random-dev', 'images', True),
                   ('random-streams', 'streams-development', True)]
    for label, inputs, random in suites:
        experiment.simulate(SimpleNamespace(
            output=root / label, images=NPC / 'result/branch-v3' / inputs,
            binary=root / 'build/obj/Vexploration_core_tb', mhz=args.mhz,
            held_out=False, latency_ns=100, beat_ns=10, random_stalls=random,
            no_observer=False, no_trace=True, memory_mode='physical'))

    # Observation must not change execution; assertions stay enabled in both runs.
    checks = []
    cases = json.loads((root / 'dev/results.json').read_text())['results']
    for case in cases[::2][:2]:
        command = [x for x in case['command'] if not x.startswith('+observer=')]
        command += ['+observer=0']
        run = subprocess.run(command, text=True, capture_output=True, check=True)
        expected = next(line for line in (root / 'dev' / (case['case']['name'] + '.log'))
                        .read_text().splitlines() if line.startswith('RESULT '))
        assert 'PASS proxy' in run.stdout and expected in run.stdout
        checks.append({'command': command, 'matched_RESULT': expected})
    archive.mkdir(parents=True)
    for label, _, _ in suites:
        shutil.copytree(root / label, archive / label)
    (archive / 'observer-neutrality.json').write_text(json.dumps(checks, indent=2) + '\n')
    shutil.copyfile(root / 'build/manifest.json', archive / 'build-manifest.json')
    shutil.copyfile(root / 'build/build.log', archive / 'build-log.txt')
    shutil.rmtree(root / 'build/obj')
    shutil.rmtree(source)
    print('PROXY COMPLETE', args.name, flush=True)


if __name__ == '__main__':
    main()
