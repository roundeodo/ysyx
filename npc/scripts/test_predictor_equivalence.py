#!/usr/bin/env python3
"""Compare the split predictor with its frozen pre-refactor implementation."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

NPC = Path(__file__).resolve().parents[1]
REFERENCE_REVISION = 'f7a8f2568ea98c9a3492f60bedd7340f936baca4'
REFERENCE_PATH = 'npc/vsrc/riscv32/core/frontend/riscv32_fetch_control_flow_predictor.sv'
REFERENCE_SHA256 = 'd1cfc006634e019ebe795be3e900768203b0d5145a22d1ec2b84902f066ecaa6'


def run(command, log):
    with log.open('w') as output:
        result = subprocess.run(command, cwd=NPC, stdout=output, stderr=subprocess.STDOUT)
    if result.returncode:
        print(log.read_text()[-12000:])
        raise SystemExit(result.returncode)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, help='Archived original source for a shallow checkout')
    parser.add_argument('--output', type=Path, default=NPC / 'build/tests/predictor-equivalence')
    parser.add_argument('defines', nargs='+', help='Configuration macros supplied by the NPC Makefile')
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    reference = (args.reference.read_bytes() if args.reference else
                 subprocess.check_output(['git', 'show', f'{REFERENCE_REVISION}:{REFERENCE_PATH}'],
                                         cwd=NPC))
    if hashlib.sha256(reference).hexdigest() != REFERENCE_SHA256:
        raise SystemExit('Reference differs from the frozen pre-split implementation')
    reference_file = output / 'riscv32_fetch_control_flow_predictor_reference.sv'
    reference_file.write_text(reference.decode().replace(
        'module riscv32_fetch_control_flow_predictor\n',
        'module riscv32_fetch_control_flow_predictor_reference\n', 1))
    rtl = NPC / 'vsrc/riscv32'
    sources = [rtl / 'common' / name for name in
               ('riscv_config_pkg.sv', 'riscv32_addr_map_pkg.sv', 'riscv32_pkg.sv')]
    sources += [rtl / 'core/frontend' / f'riscv32_{name}.sv' for name in
                ('branch_history_table', 'branch_target_buffer', 'return_address_stack',
                 'fetch_control_flow_predictor')]
    sources += [reference_file, NPC / 'tests/rtl/riscv32_predictor_equivalence_tb.sv']
    top = 'riscv32_predictor_equivalence_tb'
    command = ['verilator', '--binary', '--timing', '--assert', '-Wno-fatal', '-j', '2',
               *args.defines, '--top-module', top,
               '--Mdir', str(output / 'obj'), *map(str, sources)]
    run(command, output / 'build.log')
    run([str(output / 'obj' / f'V{top}')], output / 'run.log')
    print((output / 'run.log').read_text())
    manifest = {'reference_revision': REFERENCE_REVISION, 'reference_sha256': REFERENCE_SHA256,
                'build_command': command, 'status': 'passed',
                'sources': {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}}
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')


if __name__ == '__main__':
    main()
