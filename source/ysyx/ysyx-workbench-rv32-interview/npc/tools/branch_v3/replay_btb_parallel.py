#!/usr/bin/env python3
"""Check a frozen BTB prototype without replacing the active RTL."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

NPC = Path(__file__).resolve().parents[2]
TOOL = Path(__file__).resolve().parent
EVIDENCE = NPC / 'docs/verification/data/btb-way-parallel-20261010/experiment'
sys.path.insert(0, str(NPC / 'scripts'))
from result_workspace import ResultWorkspace


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--variant', choices=['before', 'v1', 'v2', 'v3'], required=True)
    parser.add_argument('--output', type=Path, default=NPC / 'result/branch-v3/btb-parallel-replay')
    parser.add_argument('--synthesis', choices=['none', 'module', 'core'], default='none')
    parser.add_argument('--entries', type=int, default=16)
    parser.add_argument('--ways', type=int, default=2)
    parser.add_argument('--policy', type=int, choices=range(5), default=0)
    parser.add_argument('--flow', type=Path,
                        default=NPC / 'result/sta/rv32-interrupt-20260906/toolflow')
    parser.add_argument('--keep-artifacts', action='store_true')
    args = parser.parse_args()
    source = EVIDENCE / ('before.sv' if args.variant == 'before' else f'parallel-{args.variant}.sv')
    if not source.is_file():
        parser.error(f'Frozen prototype missing: {source}')
    active = NPC / 'vsrc/riscv32/core/frontend/riscv32_btb.sv'
    active_hash = sha(active)
    environment = {**os.environ, 'NPC_HOME': str(NPC), 'OMP_NUM_THREADS': '2'}
    with ResultWorkspace(NPC, args.output, 'btb-parallel', keep=args.keep_artifacts) as run:
        rtl = run.root / 'source'
        files = [Path('common') / name for name in
                 ['riscv_config_pkg.sv', 'riscv32_addr_map_pkg.sv',
                  'riscv32_axi4_pkg.sv', 'riscv32_pkg.sv']]
        files += [Path('core/frontend') / name for name in
                  ['riscv32_btb.sv', 'riscv32_compact_btb.sv']]
        for relative in files:
            target = rtl / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            original = source if relative.name == 'riscv32_btb.sv' else NPC / 'vsrc/riscv32' / relative
            shutil.copy2(original, target)
        commands = [[sys.executable, str(TOOL / 'test_btb.py'), '--rtl', str(rtl),
                     '--output', str(run.root / 'model')]]
        configuration = {
            'variant': args.variant,
            'git_head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=NPC, text=True).strip(),
            'active_btb_sha256': active_hash,
            'prototype_sha256': sha(source),
            'model_sources': {str(relative): sha(rtl / relative) for relative in files},
            'commands': commands,
            'scope': 'Frozen BTB with current packages/core; compare full source identity before reusing old PPA',
        }
        if args.synthesis != 'none':
            flow = args.flow.resolve()
            if not (flow / 'bin/iEDA').is_file():
                parser.error(f'STA toolflow missing: {flow}')
            filelist = run.root / 'filelist.f'
            frozen = rtl / 'core/frontend/riscv32_btb.sv'
            if args.synthesis == 'core':
                original = (NPC / 'vsrc/riscv32/filelist/filelist_sta.f').read_text()
                token = '${NPC_HOME}/vsrc/riscv32/core/frontend/riscv32_btb.sv'
                if original.count(token) != 1:
                    raise ValueError('Core filelist must contain exactly one BTB source')
                filelist.write_text(original.replace(token, str(frozen)))
            else:
                filelist.write_text('\n'.join(str(rtl / relative) for relative in files) + '\n')
            commands.append([
                sys.executable, str(NPC / 'scripts/run_synthesis.py'),
                '--target', 'sta-reset' if args.synthesis == 'core' else 'sta',
                '--output', str(run.root / 'synthesis'), 'NPC_CONFIG=rv32-balanced',
                'STA_FREQUENCY_MHZ=820', 'STA_SYNTH_STRATEGY=AREA 3',
                f'STA_TOOL_DIR={flow}', f'STA_RTL_FILELIST={filelist}',
                f'NPC_BRANCH_TARGET_ENTRY_COUNT={args.entries}',
                f'NPC_BRANCH_TARGET_WAY_COUNT={args.ways}', f'NPC_BRANCH_TARGET_POLICY={args.policy}',
            ])
            if args.keep_artifacts:
                commands[-1].insert(6, '--keep-artifacts')
            if args.synthesis == 'module':
                commands[-1] += ['STA_DESIGN=riscv32_btb',
                                f'STA_SDC_FILE={NPC / "constr/riscv32_core_reset_boundary.sdc"}']
            configuration['synthesis_sources'] = {
                str(p.relative_to(NPC)): sha(p) for p in (NPC / 'vsrc/riscv32').rglob('*.sv')}
        (run.root / 'configuration.json').write_text(json.dumps(configuration, indent=2) + '\n')
        for index, command in enumerate(commands):
            with (run.root / f'command-{index}.log').open('w') as log:
                subprocess.run(command, cwd=NPC.parent, env=environment,
                               stdout=log, stderr=subprocess.STDOUT, check=True)
        if sha(active) != active_hash:
            raise RuntimeError('Active BTB changed while the isolated experiment ran')
        (run.root / 'summary.json').write_text(json.dumps({
            'variant': args.variant, 'model': 'passed', 'synthesis': args.synthesis,
            'timing': '820 MHz is a mapping target; inspect reports and probe legal frequencies',
            'active_btb_unchanged': True,
        }, indent=2) + '\n')
        print(f'PASS {args.variant}; active RTL preserved; results: {run.root}')


if __name__ == '__main__':
    main()
