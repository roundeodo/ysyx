#!/usr/bin/env python3
"""Reproduce the declared matrix in a fresh directory, with bounded concurrency."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil
import subprocess
import zlib

from explore_frontend import NPC, sha
from select_icache import CONFIGS


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--toolflow', type=Path, required=True,
                        help='Frozen yosys-sta directory including iEDA and NanGate45')
    parser.add_argument('--microbench-trace', type=Path,
                        help='Optional previously verified functional trace; never used as CPU timing')
    args = parser.parse_args()
    out, flow = args.output.resolve(), args.toolflow.resolve()
    assert (flow / 'bin/iEDA').is_file() and (flow / 'scripts/yosys.tcl').is_file()
    out.mkdir(parents=True, exist_ok=False)
    baseline = out / 'baseline'
    baseline.mkdir()
    workspace = NPC.parent
    env = dict(os.environ, NPC_STA_TOOLFLOW=str(flow))
    frozen = {}
    sources = list((NPC / 'vsrc/riscv32').rglob('*.sv'))
    sources += list((NPC / 'vsrc/riscv32').rglob('*.svh'))
    sources += list((NPC / 'scripts').glob('*.py'))
    sources += list((NPC / 'configs').glob('*.mk'))
    sources += list((NPC / 'tools/icache_explore').glob('*.py'))
    sources += list((NPC / 'tests/frontend_selection').rglob('*'))
    sources += list((NPC / 'tests/frontend_exploration').glob('*'))
    sources += list((NPC / 'tests/interrupt').glob('*'))
    sources += [workspace / 'abstract-machine/am/src/riscv/npc/libgcc/div.S',
                workspace / 'abstract-machine/am/src/riscv/npc/libgcc/muldi3.S']
    sources += [NPC / 'Makefile', NPC / 'tools/icache_explore/model.cpp',
                NPC / 'constr/riscv32_core_reset_boundary.sdc']
    for source in sorted(set(p for p in sources if p.is_file())):
        relative = source.relative_to(workspace)
        target = baseline / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        frozen[str(relative)] = sha(source)
    for args_git, filename in [(['diff', '--binary'], 'workspace.diff'),
                               (['status', '--short'], 'workspace-status.txt')]:
        content = subprocess.check_output(['git', *args_git], cwd=workspace)
        (baseline / filename).write_bytes(content)
    flow_files = [flow / 'Makefile', flow / 'bin/iEDA']
    flow_files += list((flow / 'scripts').rglob('*.tcl'))
    flow_files += [flow / 'pdk/nangate45' / p for p in
                   ['lib/Nangate45_typ.lib', 'blackbox_map.tcl', 'verilog/blackbox.v',
                    'verilog/cells_clkgate.v', 'verilog/cells_latch.v']]
    manifest = {'frozen_at': datetime.now(timezone.utc).isoformat(),
                'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=workspace, text=True).strip(),
                'sources': frozen, 'configs': CONFIGS, 'dev_seeds': [41, 73], 'held_seeds': [809, 1543],
                'objective': 'whole-core area times equal-category geometric mean legal-frequency time',
                'held_bound': 1.03, 'memory_mode': 'physical', 'toolflow': str(flow),
                'toolflow_hashes': {str(p.relative_to(flow)): sha(p) for p in flow_files},
                'tools': {tool: subprocess.check_output([tool, '--version'], text=True).splitlines()[0]
                          for tool in ['verilator', 'riscv64-linux-gnu-gcc', 'g++']}}
    manifest['tools']['yosys'] = subprocess.check_output(['yosys', '-V'], text=True).strip()
    manifest['tools']['python3'] = subprocess.check_output(['python3', '--version'], text=True).strip()
    manifest['tools']['zlib_runtime'] = zlib.ZLIB_RUNTIME_VERSION
    manifest['submodules'] = {}
    for name in ['am-kernels', 'ysyxSoC']:
        directory = workspace / name
        revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=directory, text=True).strip()
        patch = baseline / (name + '.diff')
        patch.write_bytes(subprocess.check_output(['git', 'diff', '--binary'], cwd=directory))
        manifest['submodules'][name] = {'commit': revision, 'diff_sha256': sha(patch)}
    (baseline / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')

    def run(script, *arguments):
        command = ['python3', str(NPC / 'scripts' / (script + '.py')), *map(str, arguments)]
        print('RUN', script, flush=True)
        log = out / (script + '.log')
        # A script can run twice (B0 trace followed by the rest of the matrix).
        index = 1
        while log.exists():
            log = out / f'{script}-{index}.log'
            index += 1
        with log.open('x') as stream:
            stream.write(json.dumps(command) + '\n')
            stream.flush()
            subprocess.run(command, cwd=workspace, env=env, stdout=stream,
                           stderr=subprocess.STDOUT, check=True)

    with (out / 'sta-search-tests.log').open('x') as stream:
        subprocess.run(['python3', str(NPC / 'tools/icache_explore/test_sta_search.py')],
                       cwd=workspace, env=env, stdout=stream, stderr=subprocess.STDOUT, check=True)

    run('test_reference_memory', '--output', out / 'memory-tests')

    images, rtl = out / 'images-v1', out / 'rtl'
    run('build_selection_workloads', '--output', images)
    run('test_selection_replacement', '--output', out / 'policy-tests')
    run('verify_icache_selection', '--output', out / 'safety', '--configs', 'B0', '--full')
    run('select_icache', '--output', rtl, '--images', images, '--configs', 'B0', '--host-opt', 2)
    extra = ['--extra-trace', args.microbench_trace.resolve()] if args.microbench_trace else []
    run('scan_selection', '--traces', rtl / 'dev-580/B0', '--output', out / 'model-dev', *extra)
    run('select_icache', '--output', rtl, '--images', images, '--host-opt', 2, '--no-trace')
    run('select_icache_ppa', '--output', out / 'ppa', '--configs', *CONFIGS, '--jobs', 2)
    run('run_selection_qualified', '--root', out, '--configs', *CONFIGS, '--host-opt', 2)
    run('validate_icache_selection', '--root', out)
    run('finish_icache_selection', '--root', out)
    print('COMPLETE', out / 'decision.json', flush=True)


if __name__ == '__main__':
    main()
