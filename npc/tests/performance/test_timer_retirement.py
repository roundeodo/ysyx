#!/usr/bin/env python3
"""Run the timer/exception fixture with observer on/off in the same SoC binary."""
import argparse
import json
from pathlib import Path
import re
import subprocess


def retirement_frames(path):
    """Read low-clock retirement signals independently of the host counter."""
    scope, codes, values, frames = [], {}, {}, []
    timestamp = None
    with path.open() as wave:
        for line in wave:
            fields = line.split()
            if fields[:1] == ['$scope']:
                scope.append(fields[2])
            elif fields[:1] == ['$upscope']:
                scope.pop()
            elif fields[:1] == ['$var']:
                name = '.'.join(scope + [fields[4]])
                if name == 'TOP.clock':
                    codes[fields[3]] = 'clock'
                elif name.endswith('.u_core.retired_instruction_event'):
                    codes[fields[3]] = 'retired'
            elif fields[:1] == ['$enddefinitions']:
                assert set(codes.values()) == {'clock', 'retired'}, codes
                break
        for line in wave:
            line = line.strip()
            if line.startswith('#'):
                if timestamp is not None and values['clock'] == 0:
                    frames.append(values['retired'])
                timestamp = int(line[1:])
            elif line and line[0] in '01' and line[1:] in codes:
                values[codes[line[1:]]] = int(line[0])
        if timestamp is not None and values['clock'] == 0:
            frames.append(values['retired'])
    return frames


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--simulator', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=False)
source = Path(__file__).with_name('timer_retire_boundary.S')
subprocess.run(['riscv64-linux-gnu-gcc', '-c', '-fno-pic', '-fno-pie', '-march=rv32i_zicsr',
                '-mabi=ilp32', '-o', str(output / 'fixture.o'), str(source)], check=True)
subprocess.run(['riscv64-linux-gnu-ld', '-melf32lriscv', '-Ttext=0x30000000', '--no-relax',
                '-o', str(output / 'fixture.elf'), str(output / 'fixture.o')], check=True)
subprocess.run(['riscv64-linux-gnu-objcopy', '-O', 'binary', str(output / 'fixture.elf'),
                str(output / 'fixture.bin')], check=True)
command = [str(args.simulator.resolve()), '--batch', '--itrace', '--flash',
           str(output / 'fixture.bin'), '+NPC_PERF_AUDIT']
for enabled in [True, False]:
    with (output / ('on.log' if enabled else 'off.log')).open('x') as log:
        subprocess.run(command + (['--trace', f'+NPC_PERF_OUTPUT={output}/events.jsonl'] if enabled else []),
                       cwd=output, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=60)
log = (output / 'on.log').read_text()
assert log == (output / 'off.log').read_text(), 'Observer changed CPU execution'
events = [json.loads(line) for line in (output / 'events.jsonl').read_text().splitlines()]
assert len(events) == 5
first, second, third = events[1:4]
assert second['retired'] - first['retired'] == 9, 'ECALL counted or handler retirement lost'
assert events[-1]['retired'] == 19, 'ECALL/EBREAK must not retire'
assert events[-1]['valid'] and events[-1]['good_exit']
assert all(e['successful_load'] and e['load_commit_cycle'] > e['cycle'] for e in events[1:4])
assert len(re.findall(r'itrace: 0x[0-9a-f]+:', log)) == 21

# Bypass can accept the third timer read before earlier instructions retire.
# Compare the exact pre-edge count against the wave, not a fixed program distance.
frames = retirement_frames(output / 'waveform.vcd')
reset_cycles = len(frames) - events[-1]['cycles']
assert reset_cycles > 0 and not any(frames[:reset_cycles])
frames = frames[reset_cycles:]
assert sum(frames) == 19
for sample in events[1:4]:
    assert sum(frames[:sample['cycle']]) == sample['retired'], 'Pre-edge retirement count is wrong'
    assert frames[sample['load_commit_cycle']] == 1, 'Timer load did not retire at the reported edge'
windows = [second['retired'] - first['retired'], third['retired'] - second['retired']]
(output / 'report.json').write_text(json.dumps({'status': 'passed', 'retired': 19,
    'commits_including_traps': 21, 'timer_window_retired': windows,
    'wave_retirement_counts_match': True, 'observer_on_off_identical': True}, indent=2) + '\n')
print(f'PASS: 21 commits / 19 retired; wave-checked timer windows {windows}; observer on/off identical')
