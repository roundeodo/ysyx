#!/usr/bin/env python3
"""Rebuild the branch matrix from frozen RTL and images in a fresh output tree."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import shutil
import subprocess

from explore_frontend import NPC, sha
from qualify_branch_runs import read


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, required=True, help='Original branch experiment directory')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--toolflow', type=Path, required=True, help='Same yosys-sta/iEDA/NanGate45 installation')
    parser.add_argument('--jobs', type=int, choices=[1, 2], default=2, help='Concurrent synthesis or simulation jobs')
    parser.add_argument('--check-only', action='store_true', help='Verify inputs without creating output or launching jobs')
    args = parser.parse_args()
    archive, out = args.archive.resolve(), args.output.resolve()
    assert (args.toolflow / 'bin/iEDA').is_file()
    observed_tools = {tool: subprocess.check_output([tool, '-V' if tool == 'yosys' else '--version'],
                                                    text=True).splitlines()[0]
                      for tool in read(archive / 'baseline/manifest.json')['tools']}
    assert observed_tools == read(archive / 'baseline/manifest.json')['tools'], 'Tool versions differ from frozen experiment'
    for name, expected in read(archive / 'baseline/provenance-supplement.json')['toolflow_sources'].items():
        relative = name.split('/toolflow/', 1)[1]
        assert sha(args.toolflow / relative) == expected, f'Toolflow source changed: {relative}'
    for name, metadata in read(archive / 'baseline/toolchain-files.json')['files'].items():
        path = args.toolflow / name.split('/toolflow/', 1)[1] if '/toolflow/' in name else Path(name)
        assert sha(path) == metadata['sha256'], f'Toolchain binary/library changed: {name}'
    for folder, sources in [('baseline', read(archive / 'baseline/manifest.json')['sources']),
                            ('candidate-source', read(archive / 'candidate-source/manifest.json'))]:
        for name, expected in sources.items():
            assert sha(archive / folder / name) == expected, (folder, name)
    # Safety and SoC MicroBench use repository build rules. Refuse a changed
    # implementation rather than silently combine the archive with another core.
    for name, expected in read(archive / 'candidate-source/manifest.json').items():
        assert sha(NPC.parent / name) == expected, f'Use the matching worktree for integration tests: {name}'
    if args.check_only:
        print('PASS frozen source, integration source, tool versions and toolchain hashes')
        return
    out.mkdir(parents=True, exist_ok=False)
    for folder in ['baseline', 'candidate-source', 'images']:
        shutil.copytree(archive / folder, out / folder)
    shutil.copy2(archive / 'configurations.json', out / 'configurations.json')
    env = dict(os.environ, NPC_STA_TOOLFLOW=str(args.toolflow.resolve()))

    def run(label, script, *arguments):
        command = ['python3', str(NPC / 'scripts' / (script + '.py')), *map(str, arguments)]
        with (out / (label + '.log')).open('x') as stream:
            stream.write(json.dumps(command) + '\n')
            stream.flush()
            subprocess.run(command, env=env, cwd=NPC.parent, stdout=stream,
                           stderr=subprocess.STDOUT, check=True)
        print('PASS reproduction', label, flush=True)

    run('model-tests', 'test_branch_model')
    run('direction-model-tests', 'test_direction_model')
    run('measurement-tests', 'test_branch_measurement')
    run('baseline-build', 'explore_branch', 'build', '--root', out, '--config', 'B0',
        '--source-root', out / 'baseline')
    run('baseline-run', 'explore_branch', 'run', '--root', out, '--config', 'B0', '--trace')
    run('model', 'model_branch', '--root', out, '--output', out / 'model-v3')
    run('direction-model', 'model_direction', '--root', out, '--output', out / 'direction-model-v1')
    run('direction-functions', 'profile_branch_direction', '--root', out,
        '--output', out / 'direction-model-v1/functions.json')
    run('direction-alignment', 'model_direction', '--root', out,
        '--output', out / 'direction-alignment', '--alignment-only')
    names = list(read(out / 'configurations.json'))
    run('rtl-matrix', 'run_branch_matrix', '--root', out, '--configs', *[n for n in names if n != 'B0'])
    original = read(out / 'rtl/dev-720/B0/results.json')['results']
    current = read(out / 'rtl/dev-720/B0current/results.json')['results']
    for left, right in zip(original, current):
        assert left['result'] == right['result'] and left['counters'] == right['counters']
    verification = out / 'verification'
    verification.mkdir()
    (verification / 'default-equivalence.json').write_text(json.dumps({
        'passed': True, 'cases': len(original), 'result_and_all_counters_identical': True}, indent=2) + '\n')
    command = ['make', '-C', str(NPC), 'git_commit=', 'NPC_CONFIG=rv32-balanced',
               f'FRONTEND_TEST_OUTPUT={verification / "predictor-final"}', 'test-predictor']
    with (out / 'predictor-contract.log').open('x') as stream:
        subprocess.run(command, env=env, stdout=stream, stderr=subprocess.STDOUT, check=True)

    def ppa(name):
        run('ppa-' + name, 'run_branch_ppa', '--root', out, '--configs', name,
            '--source-root', out / ('baseline' if name == 'B0' else 'candidate-source'))

    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        for _ in pool.map(ppa, names):
            pass
    run('qualified-runs', 'qualify_branch_runs', '--root', out, '--jobs', args.jobs)
    run('held-validation', 'select_branch', '--root', out, '--jobs', args.jobs)
    run('final-regressions', 'finish_branch_regressions', '--root', out)
    run('report', 'report_branch', '--root', out, '--output', out / 'summary')
    print('COMPLETE', out / 'summary/report.json', flush=True)


if __name__ == '__main__':
    main()
