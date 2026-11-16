#!/usr/bin/env python3
"""Run RV64 pipeline, frontend, cache and AXI contracts with explicit build macros."""
import argparse
import concurrent.futures
import hashlib
import itertools
import json
import os
from pathlib import Path
import resource
import subprocess

NPC = Path(__file__).resolve().parents[1]
TESTS = ['config_elaboration', 'idu_decode', 'exu_alu', 'lsu', 'pipeline_control',
         'uncached_axi4_master', 'dcache', 'axi4_core_merge', 'axi4_soc_width_converter',
         'privileged', 'axi4_handoff', 'predictor_contract', 'fetch_contract',
         'icache_contract', 'dcache_miss_contract', 'dcache_axi_contract',
         'dcache_recovery', 'fence_i_ctrl', 'scoreboard', 'scoreboard_core']


def run_test(name, output, defines, lint_only):
    top = 'riscv_' + name + '_tb'
    out = output / name
    out.mkdir(parents=True, exist_ok=True)
    sources = [NPC / 'vsrc/riscv/filelist/filelist_sta.f', NPC / 'tests/rtl' / (top + '.sv')]
    command = ['verilator', '--lint-only' if lint_only else '--binary', '--timing',
               '--assert', '-Wno-fatal', *defines, '--top-module', top,
               f'-I{NPC / "vsrc/riscv/sim"}', '-f', str(sources[0]), str(sources[1])]
    if not lint_only:
        command += ['-j', '2', '--Mdir', str(out / 'obj')]
    record = {'build_command': command, 'cases': []}
    env = dict(os.environ, NPC_HOME=str(NPC))
    with (out / 'build.log').open('w') as log:
        result = subprocess.run(command, cwd=NPC, env=env, stdout=log,
                                stderr=subprocess.STDOUT, timeout=1800)
    record['build_exit'] = result.returncode
    if not result.returncode and not lint_only:
        cases = [[]]
        if name == 'scoreboard_core':
            cases = [[f'+mode={mode}'] for mode in range(7)]
        if name == 'dcache_recovery':
            cases = [[f'+fault={fault}', f'+b_delay={bd}', f'+r_delay={rd}',
                      f'+partial={partial}', f'+store={store}', f'+response_stall={stall}']
                     for fault, (bd, rd), partial, store, stall in itertools.product(
                         [0, 2, 3], [(0, 0), (25, 0), (0, 25)], range(2), range(2), [0, 4])]
            cases += [[f'+fault={fault}', '+r_error=1', '+b_delay=25',
                       '+response_stall=4', '+store=1'] for fault in [0, 2, 3]]
        for index, options in enumerate(cases):
            run = [str(out / 'obj' / ('V' + top)), *options]
            with (out / f'run-{index}.log').open('w') as log:
                result = subprocess.run(run, stdout=log, stderr=subprocess.STDOUT, timeout=60)
            record['cases'].append({'command': run, 'exit': result.returncode})
            if result.returncode:
                break
    record['passed'] = not record['build_exit'] and all(not c['exit'] for c in record['cases'])
    (out / 'manifest.json').write_text(json.dumps(record, indent=2) + '\n')
    print(('PASS ' if record['passed'] else 'FAIL ') + name, flush=True)
    return name, record


def main():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--test', choices=TESTS, action='append')
    parser.add_argument('--lint-only', action='store_true')
    parser.add_argument('defines', nargs='+')
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(run_test, t, output, args.defines, args.lint_only)
                   for t in (args.test or TESTS)]
        results = dict(f.result() for f in concurrent.futures.as_completed(futures))
    sources = [*sorted((NPC / 'vsrc/riscv').rglob('*.sv')),
               *sorted((NPC / 'tests/rtl').glob('*.sv')), Path(__file__)]
    manifest = {'defines': args.defines, 'lint_only': args.lint_only, 'tests': results,
                'sha256': {str(p.relative_to(NPC)): hashlib.sha256(p.read_bytes()).hexdigest()
                           for p in sources}}
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    raise SystemExit(0 if all(r['passed'] for r in results.values()) else 1)


if __name__ == '__main__':
    main()
