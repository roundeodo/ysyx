#!/usr/bin/env python3
"""Build and run uninstrumented RV64 MicroBench with passive timer/retire sampling."""
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
ARCH = 'riscv64-npc'


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
    timer_wrapper = funcs.get('uptime')
    call_target = '<uptime>' if timer_wrapper else '<ioe_read>'
    calls = []
    for index, (pc, instruction, text) in enumerate(main):
        if call_target not in text:
            continue
        require(instruction & 0xfff == 0x0ef, 'Expected jal ra,ioe_read')
        if not timer_wrapper:
            require(index > 0 and main[index - 1][1] == 0x00600513,
                    'Expected AM_TIMER_UPTIME immediately before timer call')
        calls.append(pc + 4)
    require(len(calls) == 4, 'Expected four native timer call sites in main')
    if timer_wrapper:
        require(sum('<ioe_read>' in text for _, _, text in timer_wrapper) == 1,
                'Unsupported uptime wrapper')
        require(any(word == 0x00600513 for _, word, _ in timer_wrapper),
                'uptime wrapper must select AM_TIMER_UPTIME')
    low_pcs = {}
    for name in ['__am_timer_init', '__am_timer_uptime']:
        body = funcs[name]
        loads = [pc for pc, word, _ in body if word & 0xfff0707f in (0x04802003, 0x04806003)]
        require(len(loads) == 1, f'Expected one low mtime lw in {name}')
        low_pcs[name] = loads[0]
        require(any(word & 0xfffff07f == 0x02000037 for _, word, _ in body),
                f'Expected CLINT base 0x02000000 in {name}')
    # The timer and ioe_read must preserve the main call's ra until the sample.
    for name in ['ioe_read', '__am_timer_uptime']:
        for _, word, _ in funcs[name]:
            opcode, rd = word & 127, (word >> 7) & 31
            writes_rd = opcode in (0x03, 0x13, 0x17, 0x1b, 0x33, 0x37, 0x3b, 0x67, 0x6f, 0x73)
            require(not (writes_rd and rd == 1), f'{name} overwrites ra; unsupported timer context')
    # Reject our historical CSR snapshots, even if their output were disabled.
    for body in funcs.values():
        for _, word, _ in body:
            if word & 127 == 0x73 and ((word >> 12) & 7):
                require((word >> 20) not in (0xb00, 0xb80, 0xb02, 0xb82),
                        'Image contains mcycle/minstret instrumentation')
    return {'timer_context_entry_pc': timer_wrapper[0][0] if timer_wrapper else 0,
            'main_timer_return_pcs': calls, 'init_load_pc': low_pcs['__am_timer_init'],
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
    log = re.sub(r"\x1b\[[0-9;]*m", "", log)
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
    parser.add_argument('--isa', choices=['rv64i', 'rv64im'], default='rv64im',
                        help='Software ISA; the same RV64IM hardware runs either image')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--prepare-only', action='store_true')
    parser.add_argument('--verify-observer', action='store_true')
    parser.add_argument('--resume', type=Path)
    args = parser.parse_args()
    env = dict(os.environ, NPC_HOME=str(NPC), AM_HOME=str(WORKSPACE / 'abstract-machine'))
    # Query the same Make configuration used to build the simulator, including
    # command-line overrides inherited through MAKEFLAGS from `make perf`.
    if args.resume:
        output = args.resume.resolve()
        manifest = json.loads((output / 'manifest.json').read_text())
        require(manifest['environment'] == 'ysyxSoC-sdram-calibrated', 'Unsupported environment')
        for name, digest in manifest['artifacts'].items():
            require(sha256(output / name) == digest, f'Archive changed: {name}')
        scale, cpu_mhz, layout = manifest['scale'], manifest['cpu_mhz'], manifest['layout']
    else:
        config_text = subprocess.check_output(
            ['make', '-s', '-C', str(NPC), 'git_commit=', 'print-sim-config'], env=env, text=True)
        config = dict(line.split('=', 1) for line in config_text.splitlines() if '=' in line)
        cpu_mhz, scale = int(config['cpu_mhz']), args.scale
        output = (args.output or NPC / 'result/performance' /
                  datetime.now(timezone.utc).strftime('soc-%Y%m%dT%H%M%S%fZ')).resolve()
        output.mkdir(parents=True, exist_ok=False)
        build_command = ['make', '-C', str(NPC), 'git_commit=', 'build-soc']
        run_logged(build_command, output / 'simulator-build.log', env)
        bench = WORKSPACE / 'am-kernels/benchmarks/microbench'
        # Force every application/library object to use the current ISA/startup flags.
        # Preserve earlier images and results; no broad clean or source deletion.
        software_isa = args.isa + '_zicsr_zifencei'
        image_command = ['make', '-B', '-C', str(bench), f'ARCH={ARCH}',
                         f'NPC_MARCH={software_isa}',
                         f'mainargs={scale}', 'git_commit=', 'image']
        run_logged(image_command, output / 'image-build.log', env)
        for suffix in ['bin', 'elf', 'txt']:
            shutil.copy2(bench / 'build' / f'microbench-{ARCH}.{suffix}', output / f'microbench.{suffix}')
        # Decode executable instructions, not data bytes or mnemonic substrings.
        disassembly = subprocess.check_output(
            ['riscv64-linux-gnu-objdump', '-d', str(output / 'microbench.elf')], text=True)
        instruction_words = [int(word, 16) for word in re.findall(
            r'^\s*[0-9a-f]+:\s+([0-9a-f]{8})\s', disassembly, re.MULTILINE)]
        require(instruction_words, 'No executable instructions found in ELF')
        m_instruction_count = sum((word & 0x7f) in (0x33, 0x3b) and
                                  (word >> 25) == 1 for word in instruction_words)
        require(args.isa != 'rv64i' or m_instruction_count == 0,
                'RV64I software image unexpectedly contains M instructions')
        shutil.copy2(config['simulator'], output / 'simulator')
        layout = image_layout((output / 'microbench.txt').read_text())
        sources = []
        for tree in [NPC / 'vsrc', NPC / 'csrc', NPC / 'include', NPC / 'configs',
                     WORKSPACE / 'ysyxSoC/perip', WORKSPACE / 'abstract-machine', bench]:
            sources += [p for p in tree.rglob('*') if p.is_file() and
                        'build' not in p.relative_to(tree).parts and
                        (p.suffix in ('.c', '.cpp', '.h', '.S', '.mk', '.ld', '.sv', '.svh', '.v', '.f')
                         or p.name == 'Makefile')]
        sources += [NPC / 'Makefile', Path(__file__).resolve(),
                    WORKSPACE / 'ysyxSoC/build/ysyxSoCFull.v']
        sources = sorted(set(sources))
        with tarfile.open(output / 'source-snapshot.tar.gz', 'w:gz') as archive:
            for source in sources:
                archive.add(source, arcname=str(source.relative_to(WORKSPACE)))
        manifest = dict(schema=1, environment='ysyxSoC-sdram-calibrated', scale=scale,
                        cpu_mhz=cpu_mhz, device_mhz=100, timer_hz=1_000_000,
                        delay_ratio_scaled=cpu_mhz * 1024 // 100, delay_scale=1024,
                        configuration=config, isa=software_isa, layout=layout,
                        static_m_instruction_count=m_instruction_count,
                        frequency_status='simulation evaluation point; qualification requires matching STA evidence',
                        build_command=build_command, image_build_command=image_command,
                        sources={str(p.relative_to(WORKSPACE)): sha256(p) for p in sources},
                        artifacts={name: sha256(output / name) for name in
                                   ['simulator', 'microbench.bin', 'microbench.elf', 'microbench.txt',
                                    'source-snapshot.tar.gz']})
        (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    if args.prepare_only:
        print(f'Ready. Run: python3 {Path(__file__).resolve()} --resume {output}')
        return
    command = [str(output / 'simulator'), '--batch', '--flash', str(output / 'microbench.bin'),
               f"+NPC_PERF_UPTIME_PC={layout['timer_context_entry_pc']:x}"]
    started = time.monotonic()
    audit = ['+NPC_PERF_AUDIT'] if args.verify_observer else []
    print(f'Starting {scale}; ysyxSoC SDRAM, CPU={cpu_mhz} MHz, device=100 MHz.', flush=True)
    run_logged(command + audit + [f'+NPC_PERF_OUTPUT={output}/timer-events.jsonl'],
               output / 'simulation.log', env, echo=True)
    events = [json.loads(line) for line in (output / 'timer-events.jsonl').read_text().splitlines()]
    log = (output / 'simulation.log').read_text()
    require(f'input *{scale}*' in log, 'Compiled MAINARGS does not match requested scale')
    report = analyze(events, log, layout, cpu_mhz)
    report.update(scale=scale, host_wall_seconds=time.monotonic() - started,
                  observer_on_off_verified=False, manifest_sha256=sha256(output / 'manifest.json'))
    if args.verify_observer:
        run_logged(command + audit, output / 'observer-off.log', env)
        require(log == (output / 'observer-off.log').read_text(), 'Observer on/off changed simulation')
        require('NPC architectural audit =' in log, 'Missing architectural audit')
        report['observer_on_off_verified'] = True
    (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(f"PASS: {scale}, Scored {report['scored']['timer_seconds']:.6f} s, "
          f"{report['scored']['cycles']} cycles, IPC {report['scored']['ipc']:.9f}")
    print(f'Report: {output}/report.json')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError, KeyError) as error:
        raise SystemExit(f'Performance measurement rejected: {error}')
