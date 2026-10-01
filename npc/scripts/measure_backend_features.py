#!/usr/bin/env python3
"""Freeze RTL and ablate Issue/forwarding in isolated standalone builds.

These variants diagnose mechanisms; they are not supported CPU configurations.
Cycle comparisons use flat memory, not the native SoC timer or MicroBench train.
"""
import argparse
import hashlib
import json
import shutil
import subprocess
from pathlib import Path

from test_muldiv import NPC, run


def replace_once(path, old, new):
    source = path.read_text()
    if source.count(old) != 1:
        raise RuntimeError(f'Expected exactly one ablation anchor in {path}')
    path.write_text(source.replace(old, new, 1))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--cpu-mhz', type=int, default=700)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    baseline = output / 'source'
    shutil.copytree(NPC / 'vsrc', baseline / 'npc/vsrc')
    capstone = NPC.parent / 'nemu/tools/capstone/repo'
    if not (capstone / 'libcapstone.a').exists():
        capstone = NPC.parent.parent / 'ysyx-workbench/nemu/tools/capstone/repo'
    if not (capstone / 'libcapstone.a').exists():
        raise RuntimeError('Build host capstone first')
    records = {}
    for name in ['rob', 'legacy', 'without-issue', 'without-forwarding']:
        directory = output / name
        source = directory / 'source'
        shutil.copytree(baseline, source)
        rtl = source / 'npc/vsrc/riscv32'
        if name == 'without-issue':
            replace_once(rtl / 'core/riscv32_core.sv',
                         'if (BACKEND_ROB_ENABLE) begin : gen_issue',
                         "if (1'b0) begin : gen_issue")
        if name == 'without-forwarding':
            replace_once(rtl / 'core/execute/riscv32_backend.sv',
                         'if (alu_handshake && execute_tag_q',
                         "if (1'b0 && alu_handshake && execute_tag_q")
            replace_once(rtl / 'core/writeback/riscv32_rob.sv',
                         'assign producer_array_o[slot].value = completed_result_array[slot].result;',
                         'assign producer_array_o[slot].value = result_array_q[slot].result;')
            replace_once(rtl / 'core/writeback/riscv32_rob.sv',
                         '(completed_vector_q[slot] || completion_vector[slot]) &&',
                         'completed_vector_q[slot] &&')
        filelist = directory / 'filelist.f'
        filelist.write_text((rtl / 'filelist/filelist.f').read_text().replace(
            '${NPC_HOME}', str(source / 'npc')))
        build = directory / 'build'
        command = ['make', '-C', str(NPC), 'git_commit=', f'NPC_HOME={NPC}',
                   'NPC_CONFIG=rv32im-pipelined', f'NPC_SIM_CPU_FREQ_MHZ={args.cpu_mhz}',
                   f'NPC_BACKEND_ROB_ENABLE={int(name != "legacy")}',
                   'NPC_BACKEND_ENTRIES=4', f'NPC_BACKEND_LOAD_OVERLAP={int(name != "legacy")}',
                   'NPC_ASSERT_ENABLE=1', f'RTL_FILELIST={filelist}', f'BUILD_DIR={build}',
                   f'CAPSTONE_HOME={capstone}',
                   'build-npc']
        manifest = {'variant': name, 'build': command, 'cpu_mhz': args.cpu_mhz,
                    'scope': 'whole standalone program; flat memory; not physical frequency qualification',
                    'rtl_sha256': {str(p.relative_to(source)): hashlib.sha256(p.read_bytes()).hexdigest()
                                   for p in rtl.rglob('*.sv')}}
        (directory / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        print('BUILD', name, flush=True)
        run(command, directory / 'build.log')
        simulator = build / 'top_sim'
        run(['python3', str(NPC / 'scripts/test_backend_core.py'), '--simulator', str(simulator),
             '--output', str(directory / 'fu')], directory / 'fu-driver.log')
        run(['python3', str(NPC / 'scripts/measure_muldiv_kernel.py'), '--simulator', str(simulator),
             '--output', str(directory / 'kernel')], directory / 'kernel-driver.log')
        records[name] = {'fu': json.loads((directory / 'fu/report.json').read_text()),
                         'kernel': json.loads((directory / 'kernel/report.json').read_text()),
                         'manifest': str(directory / 'manifest.json')}
        (output / 'report.json').write_text(json.dumps(records, indent=2) + '\n')
        print('PASS', name, {k: v['cycles'] for k, v in records[name]['fu']['cases'].items()}, flush=True)


if __name__ == '__main__':
    main()
