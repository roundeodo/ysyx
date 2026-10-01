#!/usr/bin/env python3
"""Attribute native MicroBench windows with an isolated, read-only RTL probe.

No guest instructions, device timing, or functional RTL are changed. Cache-size
variants are diagnostic experiments, not STA-qualified implementation choices.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
from pathlib import Path
from run_microbench_perf import NPC, WORKSPACE, analyze, require, run_logged, sha256


def counter_delta(start, end):
    result = {name: end[name] - start[name] for name in ('cycles', 'retired')}
    for group in ('categories', 'events'):
        result[group] = {key: end[group][key] - start[group][key] for key in start[group]}
        require(all(x >= 0 for x in result[group].values()), 'Counter reversed')
    require(sum(result['categories'].values()) == result['cycles'], 'Dispatch partition is not exhaustive')
    require(result['events']['retire'] == result['retired'], 'Retirement counter mismatch')
    require(sum(result['events'][key] for key in ('wait_same_line', 'wait_other_line_hit',
            'wait_other_line_miss')) == result['events']['load_wait_during_miss'], 'Shadow lookup partition mismatch')
    return result


def analyze_stalls(path, events, native):
    rows = [json.loads(line) for line in path.read_text().splitlines()]
    snapshots = [row for row in rows if row['type'] == 'snapshot']
    timers = [row for row in events if row['type'] == 'timer_sample']
    require(len(snapshots) == len(timers) == 23, 'Missing native timer boundary')
    offset = snapshots[0]['cycles'] - timers[0]['cycle']
    for sample, timer in zip(snapshots, timers):
        require(sample['cycles'] - timer['cycle'] == offset, 'Probe and native edge disagree')
        require(sample['retired'] == timer['retired'], 'Probe and native retirement disagree')
        require(sample['ticks'] == timer['ticks'], 'Probe and native timer disagree')
    total = counter_delta(snapshots[1], snapshots[-1])
    windows = [counter_delta(snapshots[i], snapshots[i + 1]) for i in range(2, 22, 2)]
    scored = {name: sum(w[name] for w in windows) for name in ('cycles', 'retired')}
    for group in ('categories', 'events'):
        scored[group] = {key: sum(w[group][key] for w in windows) for key in windows[0][group]}
    for measured, expected in [(total, native['total']), (scored, native['scored'])] + list(zip(windows, native['subtests'])):
        require(measured['cycles'] == expected['cycles'], 'Window cycle mismatch')
        require(measured['retired'] == expected['retired_instructions'], 'Window retirement mismatch')
    return {'total': total, 'scored': scored, 'subtests': windows,
            'probe_minus_host_cycle_offset': offset,
            'pc_wait_whole_program': sorted((r for r in rows if r['type'] == 'pc_wait'),
                                            key=lambda r: r['cycles'], reverse=True),
            'scope': 'exclusive dispatch categories; events overlap and are not speedup predictions'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--dcache-bytes', type=int, default=256)
    parser.add_argument('--backend-rob', type=int, choices=(0, 1), default=1)
    parser.add_argument('--verify-observer', action='store_true')
    parser.add_argument('--standalone', action='store_true', help='Also build standalone simulator for directed programs')
    parser.add_argument('--source-root', type=Path, default=WORKSPACE)
    args = parser.parse_args()
    reference = args.reference.resolve()
    original = json.loads((reference / 'manifest.json').read_text())
    require(original['timing_model'] == 'device-clock-v1', 'Expected device-clock baseline')
    for name, digest in original['artifacts'].items():
        require(sha256(reference / name) == digest, f'Reference changed: {name}')
    for name, digest in original['sources'].items():
        if name.startswith(('npc/csrc/', 'npc/include/', 'ysyxSoC/')) or name == 'npc/Makefile':
            require(sha256(WORKSPACE / name) == digest, f'Host/device model changed: {name}')
    output = args.output.resolve(); output.mkdir(parents=True, exist_ok=False)
    source = output / 'source'
    shutil.copytree(args.source_root.resolve() / 'npc/vsrc', source / 'npc/vsrc')
    probe = output / 'riscv32_stall_probe.svh'
    shutil.copy2(NPC / 'tests/performance/riscv32_stall_probe.svh', probe)
    system = source / 'npc/vsrc/riscv32/system/riscv32_npc_system.sv'
    text = system.read_text(); anchor = 'endmodule : riscv32_npc_system'
    require(text.count(anchor) == 1, 'Unexpected system boundary')
    system.write_text(text.replace(anchor, f'`include "{probe}"\n\n' + anchor))
    filelist = output / 'filelist.f'
    filelist.write_text((source / 'npc/vsrc/riscv32/filelist/filelist.f').read_text().replace('${NPC_HOME}', str(source / 'npc')))
    command = list(original['build_command'])
    changes = {'BUILD_DIR': output / 'build', 'NPC_DCACHE_CAPACITY_BYTES': args.dcache_bytes,
               'NPC_BACKEND_ROB_ENABLE': args.backend_rob, 'NPC_BACKEND_LOAD_OVERLAP': args.backend_rob}
    for i, value in enumerate(command):
        key = value.split('=', 1)[0]
        if key in changes: command[i] = f'{key}={changes[key]}'
    command.insert(-1, f'RTL_FILELIST={filelist}')
    env = dict(os.environ, NPC_HOME=str(NPC), AM_HOME=str(WORKSPACE / 'abstract-machine'))
    manifest = {'reference': str(reference), 'reference_manifest_sha256': sha256(reference / 'manifest.json'),
                'cpu_mhz': original['cpu_mhz'], 'dcache_bytes': args.dcache_bytes,
                'backend_rob': args.backend_rob, 'build_command': command,
                'probe_sha256': sha256(probe), 'script_sha256': sha256(__file__),
                'rtl_sha256': {str(p.relative_to(source)): sha256(p) for p in source.rglob('*') if p.is_file()}}
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print('BUILD', output.name, flush=True)
    run_logged(command, output / 'build.log', env)
    for name in ('microbench.bin', 'microbench.elf', 'microbench.txt'):
        shutil.copy2(reference / name, output / name)
    simulator = output / 'build/ysyxSoCFull_sim'
    run_command = [str(simulator), '--batch', '--flash', str(output / 'microbench.bin'),
                   f'+NPC_PERF_OUTPUT={output}/timer-events.jsonl']
    if args.backend_rob: run_command.append(f'+NPC_STALL_OUTPUT={output}/stalls.jsonl')
    if args.verify_observer: run_command.append('+NPC_PERF_AUDIT')
    print('RUN', output.name, flush=True)
    run_logged(run_command, output / 'simulation.log', env)
    log = (output / 'simulation.log').read_text()
    events = [json.loads(line) for line in (output / 'timer-events.jsonl').read_text().splitlines()]
    report = analyze(events, log, original['layout'], original['cpu_mhz'])
    report.update(scale=original['scale'], isa=original['isa'], image_sha256=sha256(output / 'microbench.bin'),
                  simulator_sha256=sha256(simulator), run_command=run_command)
    if args.backend_rob: report['stalls'] = analyze_stalls(output / 'stalls.jsonl', events, report)
    if args.verify_observer:
        off = [s for s in run_command if not s.startswith(('+NPC_STALL_OUTPUT=', '+NPC_PERF_OUTPUT='))]
        off.append(f'+NPC_PERF_OUTPUT={output}/observer-off-events.jsonl')
        run_logged(off, output / 'observer-off.log', env)
        require((output / 'observer-off-events.jsonl').read_bytes() == (output / 'timer-events.jsonl').read_bytes(),
                'Stall probe changed native timing or retirement')
        off_log = (output / 'observer-off.log').read_text()
        audit = lambda s: [l for l in s.splitlines() if 'audit' in l.lower()]
        require(audit(log) and audit(log) == audit(off_log), 'Commit audit changed with probe')
        report['observer_equivalence'] = {'native_events_identical': True, 'audit': audit(log)}
    (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print('PASS', output.name, report['total'], report['scored'], flush=True)
    if args.standalone:
        standalone_command = [s if not s.startswith('BUILD_DIR=') else f'BUILD_DIR={output}/build-standalone' for s in command]
        standalone_command[-1] = 'build-npc'
        manifest['standalone_build_command'] = standalone_command
        (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        run_logged(standalone_command, output / 'standalone-build.log', env)


if __name__ == '__main__': main()
