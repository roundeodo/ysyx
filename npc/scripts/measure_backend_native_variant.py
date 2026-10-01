#!/usr/bin/env python3
"""Run a frozen RTL variant with an existing native MicroBench software image.

Rebuilds the CPU/device timing model at the requested frequency; does not scale
old cycles. The output records the reference archive, actual RTL, and commands.
"""
import argparse
import json
import os
import shutil
from pathlib import Path

from run_microbench_perf import NPC, WORKSPACE, analyze, require, run_logged, sha256


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', required=True, type=Path)
    parser.add_argument('--source-root', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--cpu-mhz', required=True, type=int)
    parser.add_argument('--lsu-entries', choices=[1, 2], type=int, default=1)
    parser.add_argument('--dcache-hit-under-miss', choices=[0, 1], type=int, default=0)
    parser.add_argument('--allow-build-rules-change', action='store_true',
                        help='Record both Makefile hashes; host/device source hashes must still match')
    parser.add_argument('--stall-probe', action='store_true', help='Inject and verify a read-only window observer')
    args = parser.parse_args()
    reference = args.reference.resolve()
    original = json.loads((reference / 'manifest.json').read_text())
    require(original['timing_model'] == 'device-clock-v1', 'Use a device-clock baseline')
    require(100 <= args.cpu_mhz <= 4000, 'CPU frequency out of range')
    for name, digest in original['artifacts'].items():
        require(sha256(reference / name) == digest, f'Reference artifact changed: {name}')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    source = output / 'source'
    shutil.copytree(args.source_root.resolve() / 'npc/vsrc', source / 'npc/vsrc')
    rtl = source / 'npc/vsrc/riscv32'
    if args.stall_probe:
        probe = output / 'riscv32_stall_probe.svh'
        shutil.copy2(NPC / 'tests/performance/riscv32_stall_probe.svh', probe)
        system = rtl / 'system/riscv32_npc_system.sv'
        anchor = 'endmodule : riscv32_npc_system'
        text = system.read_text()
        require(text.count(anchor) == 1, 'Unexpected system boundary')
        system.write_text(text.replace(anchor, f'`include "{probe}"\n\n' + anchor))
    filelist = output / 'filelist.f'
    filelist.write_text((rtl / 'filelist/filelist.f').read_text().replace(
        '${NPC_HOME}', str(source / 'npc')))
    build = output / 'build'
    command = list(original['build_command'])
    for i, value in enumerate(command):
        if value.startswith('BUILD_DIR='):
            command[i] = f'BUILD_DIR={build}'
        if value.startswith('NPC_SIM_CPU_FREQ_MHZ='):
            command[i] = f'NPC_SIM_CPU_FREQ_MHZ={args.cpu_mhz}'
    command.insert(-1, f'RTL_FILELIST={filelist}')
    command.insert(-1, f'NPC_LSU_ENTRIES={args.lsu_entries}')
    command.insert(-1, f'NPC_DCACHE_HIT_UNDER_MISS={args.dcache_hit_under_miss}')
    env = dict(os.environ, NPC_HOME=str(NPC), AM_HOME=str(WORKSPACE / 'abstract-machine'))
    # Host/device sources are shared with the reference; reject silent model edits.
    for name, digest in original['sources'].items():
        if name.startswith(('npc/csrc/', 'npc/include/', 'ysyxSoC/')) or (name == 'npc/Makefile' and not args.allow_build_rules_change):
            require(sha256(WORKSPACE / name) == digest, f'Host/device source changed: {name}')
    manifest = {'reference': str(reference), 'reference_manifest_sha256': sha256(reference / 'manifest.json'),
                'probe_sha256': sha256(probe) if args.stall_probe else None,
                'script_sha256': sha256(__file__),
                'lsu_entries': args.lsu_entries, 'dcache_hit_under_miss': args.dcache_hit_under_miss,
                'makefile_sha256': sha256(NPC / 'Makefile'),
                'reference_makefile_sha256': original['sources'].get('npc/Makefile'),
                'allow_build_rules_change': args.allow_build_rules_change,
                'cpu_mhz': args.cpu_mhz, 'device_mhz': 100, 'timing_model': original['timing_model'],
                'build_command': command, 'rtl_sha256': {
                    str(p.relative_to(source)): sha256(p) for p in rtl.rglob('*') if p.is_file()}}
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    run_logged(command, output / 'build.log', env)
    for name in ['microbench.bin', 'microbench.elf', 'microbench.txt']:
        shutil.copy2(reference / name, output / name)
    simulator = build / 'ysyxSoCFull_sim'
    run_command = [str(simulator), '--batch', '--flash', str(output / 'microbench.bin'),
                   f'+NPC_PERF_OUTPUT={output}/timer-events.jsonl']
    if args.stall_probe:
        run_command += [f'+NPC_STALL_OUTPUT={output}/stalls.jsonl', '+NPC_PERF_AUDIT']
    run_logged(run_command, output / 'simulation.log', env)
    log = (output / 'simulation.log').read_text()
    require(f'input *{original["scale"]}*' in log, 'Scale mismatch')
    events = [json.loads(line) for line in (output / 'timer-events.jsonl').read_text().splitlines()]
    report = analyze(events, log, original['layout'], args.cpu_mhz)
    if args.stall_probe:
        from measure_lsu_stalls import analyze_stalls
        report['stalls'] = analyze_stalls(output / 'stalls.jsonl', events, report)
        off = [s for s in run_command if not s.startswith(('+NPC_STALL_OUTPUT=', '+NPC_PERF_OUTPUT='))]
        off.append(f'+NPC_PERF_OUTPUT={output}/observer-off-events.jsonl')
        run_logged(off, output / 'observer-off.log', env)
        require((output / 'observer-off-events.jsonl').read_bytes() == (output / 'timer-events.jsonl').read_bytes(),
                'Observer changed timer or retirement boundaries')
        audit = lambda text: [line for line in text.splitlines() if 'audit' in line.lower()]
        require(audit(log) and audit(log) == audit((output / 'observer-off.log').read_text()),
                'Observer changed commit audit')
        report['observer_equivalence'] = {'events_identical': True, 'audit': audit(log)}
    report.update(scale=original['scale'], isa=original['isa'],
                  timing_model=original['timing_model'], simulator_sha256=sha256(simulator),
                  image_sha256=sha256(output / 'microbench.bin'),
                  manifest_sha256=sha256(output / 'manifest.json'), run_command=run_command)
    (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print('PASS', report['total'], report['scored'], flush=True)


if __name__ == '__main__':
    main()
