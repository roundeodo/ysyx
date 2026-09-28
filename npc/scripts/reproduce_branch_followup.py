#!/usr/bin/env python3
"""Reproduce the frozen followup matrix in a new directory; never overwrite RTL.

Use --check-only first. Full reproduction is deliberately expensive: every
selected configuration is freshly mapped with the same library and STA flow.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import shutil
import subprocess
from explore_frontend import NPC, sha
from finalize_branch_followup import CANDIDATES

BASELINE_NAMES = {'B0', 'O0', 'S32', 'A32', 'R32'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--toolflow', type=Path, required=True)
    parser.add_argument('--check-only', action='store_true')
    args = parser.parse_args()
    archive, output = args.archive.resolve(), args.output.resolve()
    tools = json.loads((archive / 'toolchain.json').read_text())
    for name, version in tools['versions'].items():
        observed = subprocess.check_output([name, '-V' if name == 'yosys' else '--version'], text=True).splitlines()[0]
        assert observed == version, name
    for name, metadata in tools['files'].items():
        if '/toolflow/' in name:
            path = args.toolflow / name.split('/toolflow/', 1)[1]
        else:
            path = Path(name)
            if not path.is_absolute():
                path = NPC.parent / path
        assert sha(path) == metadata['sha256'], name
    baseline = json.loads((archive / 'baseline-manifest.json').read_text())['files']
    candidate = json.loads((archive / 'candidate-source/manifest.json').read_text())
    for directory, files in [('baseline', baseline), ('candidate-source', candidate)]:
        for name, expected in files.items():
            assert sha(archive / directory / name) == expected, (directory, name)
    # Integration suites use the live checkout. Refuse another implementation.
    for name, expected in candidate.items():
        if name.startswith(('npc/vsrc/', 'npc/tests/rtl/')):
            assert sha(NPC.parent / name) == expected, name
    for name, expected in json.loads((archive / 'execution-sources.json').read_text()).items():
        assert sha(NPC.parent / name) == expected, name
    images = json.loads((archive / 'images/manifest.json').read_text())
    assert len(images['cases']) == 22
    for case in images['cases']:
        for name, expected in case['hashes'].items():
            assert sha(archive / 'images' / case['name'] / name) == expected
    if args.check_only:
        print('PASS frozen RTL, software, scripts, tools and physical timing inputs')
        return
    output.mkdir(parents=True, exist_ok=False)
    for directory in ['baseline', 'candidate-source', 'images']:
        shutil.copytree(archive / directory, output / directory)
    for name in ['baseline-manifest.json', 'configurations.json', 'toolchain.json', 'execution-sources.json']:
        shutil.copy2(archive / name, output / name)
    env = dict(os.environ, NPC_STA_TOOLFLOW=str(args.toolflow.resolve()))

    def run(label, script, *arguments):
        command = ['python3', str(NPC / 'scripts' / (script + '.py')), *map(str, arguments)]
        with (output / (label + '.log')).open('x') as stream:
            stream.write(json.dumps(command) + '\n')
            stream.flush()
            subprocess.run(command, cwd=NPC.parent, env=env, stdout=stream,
                           stderr=subprocess.STDOUT, check=True)
        print('PASS', label, flush=True)

    run('images-reproduction', 'build_branch_workloads', '--output', output / 'images-reproduction')
    for script in ['test_direction_model', 'test_branch_model', 'test_followup_measurement']:
        run(script, script)
    run('direction-contract', 'test_direction_rtl', '--output', output / 'verification/direction-first')
    names = list(json.loads((output / 'configurations.json').read_text()))

    def build(name):
        source = output / ('baseline' if name in BASELINE_NAMES else 'candidate-source')
        run('build-' + name, 'followup_branch', 'build', '--root', output,
            '--config', name, '--source-root', source)

    with ThreadPoolExecutor(max_workers=2) as pool:
        list(pool.map(build, names))
    # B0 and O0 traces are the only traces consumed by model/diagnostic stages.
    def measure(name):
        extra = ['--trace'] if name in ['B0', 'O0'] else []
        run('dev-' + name, 'followup_branch', 'run', '--root', output, '--config', name, *extra)

    with ThreadPoolExecutor(max_workers=2) as pool:
        list(pool.map(measure, names))
    run('model', 'model_branch_followup', '--root', output)
    run('functions', 'profile_branch_followup', '--root', output)
    run('diagnostic-build', 'build_prediction_diagnostic', '--root', output)
    run('diagnostic-run', 'run_prediction_diagnostic', '--root', output)
    run('history-age', 'observe_direction_history', '--root', output)
    run('safety', 'verify_branch', '--root', output, '--direction-study',
        '--configs', 'B0current', 'G64', 'M64', 'G128')
    run('difftest', 'verify_direction_difftest', '--root', output, '--configs', 'G64', 'M64', 'G128')

    def ppa(name):
        run('ppa-' + name, 'followup_branch_ppa', '--root', output, '--configs', name)

    with ThreadPoolExecutor(max_workers=2) as pool:
        list(pool.map(ppa, CANDIDATES + ['B0current']))
    run('own-clock', 'run_branch_clock_matrix', '--root', output,
        '--configs', *CANDIDATES, 'B0current')
    run('held-and-sensitivity', 'finalize_branch_followup', '--root', output)
    for name, entries, policy in [('B0current', 16, 0), ('G128', 128, 1)]:
        run('microbench-' + name, 'run_microbench_perf', '--scale', 'test', '--cpu-mhz', '660',
            '--icache-bytes', '1024', '--icache-ways', '4', '--icache-line', '32', '--icache-policy', '13',
            '--bht-entries', entries, '--direction-policy', policy, '--history-bits', '4',
            '--verify-observer', '--output', output / 'microbench' / name)
    qualified_mhz = min(json.loads((output / 'ppa' / name / 'qualified.json').read_text())['mhz']
                        for name in ['B0current', 'G128'])
    for name, entries, policy in [('B0current', 16, 0), ('G128', 128, 1)]:
        run('microbench-legal-' + name, 'run_microbench_perf', '--scale', 'test',
            '--cpu-mhz', qualified_mhz, '--icache-bytes', '1024', '--icache-ways', '4',
            '--icache-line', '32', '--icache-policy', '13', '--bht-entries', entries,
            '--direction-policy', policy, '--history-bits', '4', '--host-opt', '2',
            '--verify-observer', '--output', output / 'microbench-legal' / name)
    (output / 'microbench-legal-complete.json').write_text(json.dumps(
        {'mhz': qualified_mhz, 'configs': ['B0current', 'G128']}, indent=2) + '\n')
    run('derived-diagnostics', 'derive_branch_diagnostics', '--root', output)
    run('audit', 'audit_branch_followup', '--root', output)
    print('COMPLETE', output / 'evaluation-complete.json')


if __name__ == '__main__':
    main()
