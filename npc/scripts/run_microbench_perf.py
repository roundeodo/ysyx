#!/usr/bin/env python3
"""Build and run uninstrumented RV32 MicroBench with passive timer/retire sampling."""
import argparse
from decimal import Decimal
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import tarfile
from datetime import datetime, timezone

NPC = Path(__file__).resolve().parents[1]
WORKSPACE = NPC.parent
ARCH = 'riscv32-ysyxsoc-sdram'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def functions(disassembly):
    result = {}
    current = None
    for line in disassembly.splitlines():
        header = re.match(r'^([0-9a-f]+) <([^>]+)>:', line)
        if header:
            current = header[2]
            result[current] = []
        instruction = re.match(r'^\s*([0-9a-f]+):\s+([0-9a-f]{8})\s+(.*)', line)
        if instruction and current:
            result[current].append((int(instruction[1], 16), int(instruction[2], 16), instruction[3]))
    return result


def image_layout(disassembly):
    """Support the existing -Os, inlined uptime + tail-dispatched AM timer.

    Fail on different compiler shapes instead of assuming addresses or inserting
    noinline/markers. The native four call sites are distinguished again by the
    observed context sequence and by both printed timer totals.
    """
    funcs = functions(disassembly)
    for name in ['main', 'ioe_read', '__am_timer_init', '__am_timer_uptime']:
        require(name in funcs, f'Unsupported image: missing {name}')
    main = funcs['main']
    calls = []
    for index, (pc, instruction, text) in enumerate(main):
        if '<ioe_read>' not in text:
            continue
        require(instruction & 0xfff == 0x0ef, 'Expected jal ra,ioe_read')
        require(index > 0 and main[index - 1][1] == 0x00600513,
                'Expected AM_TIMER_UPTIME (a0=6) immediately before timer call')
        calls.append(pc + 4)
    require(len(calls) == 4, 'Expected four native timer call sites in main')
    low_pcs = {}
    for name in ['__am_timer_init', '__am_timer_uptime']:
        body = funcs[name]
        loads = [pc for pc, word, _ in body if word & 0xfff0707f == 0x04802003]
        require(len(loads) == 1, f'Expected one low mtime lw in {name}')
        low_pcs[name] = loads[0]
        require(any(word & 0xfffff07f == 0x02000037 for _, word, _ in body),
                f'Expected CLINT base 0x02000000 in {name}')
    # The timer and ioe_read must preserve the main call's ra until the sample.
    for name in ['ioe_read', '__am_timer_uptime']:
        for _, word, _ in funcs[name]:
            opcode, rd = word & 127, (word >> 7) & 31
            writes_rd = opcode in (0x03, 0x13, 0x17, 0x33, 0x37, 0x67, 0x6f, 0x73)
            require(not (writes_rd and rd == 1), f'{name} overwrites ra; unsupported timer context')
    # Reject our historical CSR snapshots, even if their output were disabled.
    for body in funcs.values():
        for _, word, _ in body:
            if word & 127 == 0x73 and ((word >> 12) & 7):
                require((word >> 20) not in (0xb00, 0xb80, 0xb02, 0xb82),
                        'Image contains mcycle/minstret instrumentation')
    return {'main_timer_return_pcs': calls, 'init_load_pc': low_pcs['__am_timer_init'],
            'uptime_load_pc': low_pcs['__am_timer_uptime']}


def interval(begin, end, config):
    cycles = end['cycle'] - begin['cycle']
    retired = end['retired'] - begin['retired']
    ticks = end['ticks'] - begin['ticks']
    require(cycles > 0 and 0 <= retired <= cycles and ticks >= 0, 'Invalid counter delta')
    require(abs(ticks * config['cpu_hz'] - cycles * config['timer_hz']) < config['cpu_hz'],
            'Timer/cycle difference exceeds one timer tick; check edge or frequency')
    return {'cycles': cycles, 'retired_instructions': retired, 'ipc': retired / cycles,
            'timer_ticks': ticks, 'timer_seconds': ticks / config['timer_hz'],
            'cycle_seconds': cycles / config['cpu_hz'],
            'interrupts': end['interrupts'] - begin['interrupts']}


def analyze(events, log, layout, cpu_mhz):
    require(len(events) == 25, 'Expected configuration, 23 timer samples, and finish')
    config, finish = events[0], events[-1]
    require(config.get('type') == 'configuration' and config.get('schema') == 1 and
            config.get('boundary') == 'pre_rising_edge', 'Unsupported observer schema')
    require(config['cpu_hz'] == cpu_mhz * 1_000_000 and config['timer_hz'] == 1_000_000,
            'Simulator frequency does not match requested timing configuration')
    require(finish.get('type') == 'finish' and finish['valid'] and finish['good_exit'],
            'Incomplete or unsuccessful simulation')
    require(finish['clint_writes'] == 0, 'CLINT writes invalidate this default timing audit')
    samples = events[1:-1]
    for index, sample in enumerate(samples):
        require(sample.get('type') == 'timer_sample' and sample['successful_load'],
                'Timer read did not retire successfully')
        require(sample['load_commit_cycle'] >= sample['cycle'], 'Commit precedes sample')
        if index:
            require(sample['cycle'] > samples[index - 1]['load_commit_cycle'],
                    'Duplicate, overlapping, or reordered timer reads')
            require(sample['retired'] >= samples[index - 1]['retired'], 'Retirement counter reversed')
    require(samples[0]['load_pc'] == layout['init_load_pc'], 'Missing initial AM timer read')
    timed = samples[1:]
    require(all(s['load_pc'] == layout['uptime_load_pc'] for s in timed),
            'Unexpected timer caller; cannot infer measurement window')
    total_begin, total_end = timed[0], timed[-1]
    scored = timed[1:-1]
    contexts = [total_begin['return_pc'], scored[0]['return_pc'],
                scored[1]['return_pc'], total_end['return_pc']]
    require(len(set(contexts)) == 4 and set(contexts) == set(layout['main_timer_return_pcs']),
            'Native timer call contexts do not match the bound ELF')
    require([s['return_pc'] for s in scored] == contexts[1:3] * 10,
            'Expected ten begin/end pairs at the same native scoring call sites')
    require('MicroBench PASS' in log and 'HIT GOOD TRAP' in log and
            log.count('Passed.') == 10 and 'Failed.' not in log and 'Ignored' not in log,
            'All ten benchmarks must pass without skipped cases')
    require('MicroBench PMU' not in log, 'CSR diagnostic image is not a passive measurement')
    windows = [interval(scored[i], scored[i + 1], config) for i in range(0, 20, 2)]
    total = interval(total_begin, total_end, config)
    cycles = sum(w['cycles'] for w in windows)
    retired = sum(w['retired_instructions'] for w in windows)
    ticks = sum(w['timer_ticks'] for w in windows)
    score = {'cycles': cycles, 'retired_instructions': retired, 'ipc': retired / cycles,
             'timer_ticks': ticks, 'timer_seconds': ticks / config['timer_hz'],
             'cycle_seconds': cycles / config['cpu_hz'],
             'interrupts': sum(w['interrupts'] for w in windows)}
    for label, measurement in [('Scored', score), ('Total', total)]:
        matches = re.findall(rf'{label}\s+time:\s*([0-9.]+) ms', log)
        require(len(matches) == 1, f'Missing unique native {label} time')
        native_us = Decimal(matches[0]) * 1000
        require(native_us == measurement['timer_ticks'], f'{label} native and observed timer disagree')
    require(finish['cycles'] > total_end['cycle'] and finish['retired'] >= total_end['retired'],
            'Invalid program finish counters')
    return {'status': 'passed', 'measurement': 'native timer windows, passive retirement counting',
            'cpu_mhz': cpu_mhz, 'device_mhz': 100, 'timer_hz': config['timer_hz'],
            'total': total, 'scored': score, 'subtests': windows,
            'whole_program': {'cycles': finish['cycles'], 'retired_instructions': finish['retired'],
                              'ipc': finish['retired'] / finish['cycles'],
                              'cycle_seconds': finish['cycles'] / config['cpu_hz'],
                              'interrupts': finish['interrupts']},
            'timer_contexts': dict(zip(['total_begin', 'score_begin', 'score_end', 'total_end'], contexts))}


def run_logged(command, path, env, echo=False):
    with path.open('x') as output:
        process = subprocess.Popen(command, cwd=WORKSPACE, env=env,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        for line in process.stdout:
            output.write(line)
            output.flush()
            if echo:
                print(line, end='', flush=True)
        returncode = process.wait()
    require(returncode == 0, f'Command failed ({returncode}); see {path}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--scale', choices=['test', 'train'], default='train')
    parser.add_argument('--cpu-mhz', type=int, default=820)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--icache-bytes', type=int, default=256)
    parser.add_argument('--icache-ways', type=int, default=1)
    parser.add_argument('--icache-policy', type=int, choices=range(17), default=0)
    parser.add_argument('--icache-line', type=int, choices=[4, 8, 16, 32, 64], default=16)
    parser.add_argument('--bht-entries', type=int, default=16)
    parser.add_argument('--btb-entries', type=int, default=16)
    parser.add_argument('--btb-ways', type=int, default=2)
    parser.add_argument('--btb-target-bits', type=int, nargs='+',
                        help='Target bits per way, low address bits retained; omitted selects original BTB')
    parser.add_argument('--btb-policy', type=int, choices=range(4), default=0)
    parser.add_argument('--ras-entries', type=int, default=4)
    parser.add_argument('--direction-policy', type=int, choices=range(5), default=0)
    parser.add_argument('--history-bits', type=int, default=4)
    parser.add_argument('--host-opt', type=int, choices=[1, 2, 3], default=3,
                        help='Host simulator optimization only; does not change guest flags or timing parameters')
    parser.add_argument('--prepare-only', action='store_true', help='Build and archive; do not simulate')
    parser.add_argument('--verify-observer', action='store_true', help='Run identical image on/off and compare audit')
    parser.add_argument('--resume', type=Path, help='Run an existing prepare-only directory, checking hashes')
    args = parser.parse_args()
    target_way_bits = 0
    if args.btb_target_bits:
        require(args.btb_ways in [2, 4] and len(args.btb_target_bits) == args.btb_ways,
                'Compact BTB needs one width for each of two or four ways')
        require(all(1 <= width <= 32 for width in args.btb_target_bits), 'Target bits must be 1..32')
        target_way_bits = sum(width << (8 * way) for way, width in enumerate(args.btb_target_bits))
    require(100 <= args.cpu_mhz <= 4000, 'CPU MHz must be 100..4000')
    env = dict(os.environ, NPC_HOME=str(NPC), AM_HOME=str(WORKSPACE / 'abstract-machine'))
    if args.resume:
        output = args.resume.resolve()
        manifest = json.loads((output / 'manifest.json').read_text())
        args.cpu_mhz, args.scale = manifest['cpu_mhz'], manifest['scale']
        for name, digest in manifest['artifacts'].items():
            require(sha256(output / name) == digest, f'Archived artifact changed: {name}')
        layout = manifest['layout']
    else:
        output = (args.output or NPC / 'result/performance' /
                  ('passive-' + args.scale + '-' + datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ'))).resolve()
        output.mkdir(parents=True, exist_ok=False)
        print(f'Artifacts: {output}', flush=True)
        print('Building RV32 simulator and uninstrumented MicroBench...', flush=True)
        build_tag = (f'cpu-{args.cpu_mhz}mhz-ic-{args.icache_bytes}-{args.icache_ways}'
                     f'-p{args.icache_policy}-l{args.icache_line}-bht-{args.bht_entries}'
                     f'-btb-{args.btb_entries}x{args.btb_ways}-p{args.btb_policy}-ras-{args.ras_entries}'
                     f'-dir-{args.direction_policy}-hist-{args.history_bits}')
        if args.btb_target_bits:
            build_tag += '-targetbits-' + '-'.join(map(str, args.btb_target_bits))
        if args.host_opt != 3:
            build_tag += f'-host-o{args.host_opt}'
        build = NPC / 'build/passive-perf' / build_tag
        flags = ('-MMD --build -cc -Wall -Wno-fatal -O3 --x-assign fast --x-initial fast '
                 f'-I{NPC}/vsrc/riscv32/sim --trace --autoflush --timescale 1ns/1ns --no-timing -j 1 '
                 f'-MAKEFLAGS "OPT_FAST=-O{args.host_opt} OPT_GLOBAL=-O{args.host_opt} OPT_SLOW=-O1"')
        command = ['make', '-C', str(NPC), 'git_commit=', 'NPC_CONFIG=rv32-baseline',
                   f'NPC_SIM_CPU_FREQ_MHZ={args.cpu_mhz}', f'BUILD_DIR={build}',
                   f'NPC_ICACHE_CAPACITY_BYTES={args.icache_bytes}', f'NPC_ICACHE_WAY_COUNT={args.icache_ways}',
                   f'NPC_ICACHE_REPLACEMENT_POLICY={args.icache_policy}', f'NPC_ICACHE_LINE_BYTES={args.icache_line}',
                   'NPC_DCACHE_ENABLE=1', 'NPC_DCACHE_CAPACITY_BYTES=256', 'NPC_DCACHE_WAY_COUNT=2',
                   'NPC_DCACHE_LINE_BYTES=16', f'NPC_BRANCH_HISTORY_ENTRY_COUNT={args.bht_entries}',
                   f'NPC_BRANCH_TARGET_ENTRY_COUNT={args.btb_entries}',
                   f'NPC_BRANCH_TARGET_WAY_COUNT={args.btb_ways}',
                   f'NPC_BRANCH_TARGET_POLICY={args.btb_policy}',
                   f'NPC_BRANCH_TARGET_WAY_BITS={target_way_bits}',
                   f'NPC_BRANCH_DIRECTION_POLICY={args.direction_policy}',
                   f'NPC_BRANCH_GLOBAL_HISTORY_BITS={args.history_bits}',
                   f'NPC_RETURN_STACK_ENTRY_COUNT={args.ras_entries}', 'NPC_SDRAM_NATIVE_READ_BURST=1',
                   f'VERILATOR_FLAGS={flags}', 'build-soc']
        # Use the worktree's capstone if present; a sibling tool installation is
        # acceptable because it is host-only and its library is recorded.
        capstone = WORKSPACE / 'nemu/tools/capstone/repo'
        if not (capstone / 'libcapstone.a').exists():
            capstone = WORKSPACE.parent / 'ysyx-workbench/nemu/tools/capstone/repo'
        require((capstone / 'libcapstone.a').exists(), 'Build host capstone first')
        command.insert(-1, f'CAPSTONE_HOME={capstone}')
        run_logged(command, output / 'simulator-build.log', env)
        bench = WORKSPACE / 'am-kernels/benchmarks/microbench'
        # Rebuild this target's objects so prior diagnostic flags cannot survive.
        run_logged(['make', '-C', str(bench), f'ARCH={ARCH}', 'git_commit=', 'clean'],
                   output / 'image-clean.log', env)
        image_command = ['make', '-C', str(bench), f'ARCH={ARCH}', f'mainargs={args.scale}',
                         'git_commit=', 'MICROBENCH_CSR_DIAGNOSTICS=0', 'image']
        run_logged(image_command, output / 'image-build.log', env)
        for suffix in ['bin', 'elf', 'txt']:
            shutil.copy2(bench / 'build' / f'microbench-{ARCH}.{suffix}', output / f'microbench.{suffix}')
        shutil.copy2(build / 'ysyxSoCFull_sim', output / 'simulator')
        layout = image_layout((output / 'microbench.txt').read_text())
        sources = list((NPC / 'vsrc/riscv32').rglob('*.sv')) + list((NPC / 'vsrc/riscv32').rglob('*.svh'))
        sources += list((NPC / 'csrc').glob('*.cpp')) + list((NPC / 'include').glob('*.h'))
        sources += list((WORKSPACE / 'ysyxSoC/perip').rglob('*.v'))
        sources += [NPC / 'Makefile', Path(__file__).resolve(), bench / 'src/bench.c',
                    WORKSPACE / 'abstract-machine/am/src/riscv/ysyxsoc/timer.c',
                    WORKSPACE / 'ysyxSoC/build/ysyxSoCFull.v']
        for tree in [bench, WORKSPACE / 'abstract-machine']:
            sources += [p for p in tree.rglob('*') if p.is_file() and
                        'build' not in p.relative_to(tree).parts and
                        (p.suffix in ('.c', '.h', '.S', '.s', '.mk', '.ld') or p.name == 'Makefile')]
        sources = sorted(set(sources))
        with tarfile.open(output / 'source-snapshot.tar.gz', 'w:gz') as archive:
            for source in sources:
                archive.add(source, arcname=str(source.relative_to(WORKSPACE)))
        manifest = {'schema': 1, 'scale': args.scale, 'cpu_mhz': args.cpu_mhz,
                    'host_opt': args.host_opt,
                    'icache': {'bytes': args.icache_bytes, 'ways': args.icache_ways,
                               'policy': args.icache_policy, 'line_bytes': args.icache_line},
                    'predictor': {'bht_entries': args.bht_entries, 'btb_entries': args.btb_entries,
                                  'btb_ways': args.btb_ways, 'btb_policy': args.btb_policy,
                                  'ras_entries': args.ras_entries,
                                  'direction_policy': args.direction_policy, 'history_bits': args.history_bits,
                                  'target_bits': args.btb_target_bits, 'target_way_bits': target_way_bits},
                    'device_mhz': 100, 'delay_ratio_scaled': args.cpu_mhz * 1024 // 100,
                    'delay_scale': 1024, 'layout': layout, 'build_command': command,
                    'image_build_command': image_command, 'reset_cycles': 10,
                    'initial_state': 'fresh simulator process; reset invalidates caches and predictor',
                    'interrupt_policy': 'native benchmark configuration; count handler retirements and cycles',
                    'capstone_sha256': sha256(capstone / 'libcapstone.a'),
                    'tools': {tool: subprocess.check_output([tool, '--version'], text=True).splitlines()[0]
                              for tool in ['verilator', 'riscv64-linux-gnu-gcc', 'riscv64-linux-gnu-ld']},
                    'git_head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=WORKSPACE, text=True).strip(),
                    'sources': {str(p.relative_to(WORKSPACE)): sha256(p) for p in sources},
                    'artifacts': {name: sha256(output / name) for name in
                                  ['simulator', 'microbench.bin', 'microbench.elf', 'microbench.txt', 'source-snapshot.tar.gz']}}
        (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    if args.prepare_only:
        print(f'Ready. Run: python3 {Path(__file__).resolve()} --resume {output}', flush=True)
        return
    # Exclusive log creation also prevents concurrent or accidental repeat runs.
    command = [str(output / 'simulator'), '--batch', '--flash', str(output / 'microbench.bin')]
    audit = ['+NPC_PERF_AUDIT'] if args.verify_observer else []
    started = time.monotonic()
    print(f'Starting {args.scale}; CPU={args.cpu_mhz} MHz, device=100 MHz.', flush=True)
    run_logged(command + audit + [f'+NPC_PERF_OUTPUT={output}/timer-events.jsonl'],
               output / 'simulation.log', env, echo=True)
    wall_seconds = time.monotonic() - started
    events = [json.loads(line) for line in (output / 'timer-events.jsonl').read_text().splitlines()]
    log = (output / 'simulation.log').read_text()
    require(f'input *{args.scale}*' in log, 'Compiled MAINARGS does not match requested scale')
    report = analyze(events, log, layout, args.cpu_mhz)
    report.update(scale=args.scale, host_wall_seconds=wall_seconds,
                  observer_on_off_verified=False, manifest_sha256=sha256(output / 'manifest.json'))
    if args.verify_observer:
        print('Verifying observer off with the same simulator and image...', flush=True)
        run_logged(command + audit, output / 'observer-off.log', env)
        off_log = (output / 'observer-off.log').read_text()
        require(len(re.findall(r'NPC architectural audit = [0-9a-f]{16}', log)) == 1,
                'Missing architectural/side-effect audit')
        require(log == off_log, 'Observer on/off differs in output, counters, or architectural audit')
        report['observer_on_off_verified'] = True
    (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(f"\nPASS: {args.scale} native Total time = {report['total']['timer_seconds']:.6f} s; "
          f"same-window IPC = {report['total']['ipc']:.9f}")
    print(f"      native Scored time = {report['scored']['timer_seconds']:.6f} s; "
          f"same-window IPC = {report['scored']['ipc']:.9f}")
    print(f'Report: {output}/report.json')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError, KeyError) as error:
        raise SystemExit(f'Performance measurement rejected: {error}')
