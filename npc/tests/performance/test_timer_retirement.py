#!/usr/bin/env python3
"""Run the timer/exception fixture with observer on/off in the same SoC binary."""
import argparse
import json
from pathlib import Path
import re
import subprocess

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
        subprocess.run(command + ([f'+NPC_PERF_OUTPUT={output}/events.jsonl'] if enabled else []),
                       stdout=log, stderr=subprocess.STDOUT, check=True, timeout=60)
log = (output / 'on.log').read_text()
assert log == (output / 'off.log').read_text(), 'Observer changed CPU execution'
events = [json.loads(line) for line in (output / 'events.jsonl').read_text().splitlines()]
assert len(events) == 5
first, second, third = events[1:4]
assert second['retired'] - first['retired'] == 9, 'ECALL counted or handler retirement lost'
assert third['retired'] - second['retired'] == 3, 'Timer-window retirement boundary is wrong'
assert events[-1]['retired'] == 19, 'ECALL/EBREAK must not retire'
assert events[-1]['valid'] and events[-1]['good_exit']
assert all(e['successful_load'] and e['load_commit_cycle'] > e['cycle'] for e in events[1:4])
assert len(re.findall(r'itrace: 0x[0-9a-f]+:', log)) == 21
(output / 'report.json').write_text(json.dumps({'status': 'passed', 'retired': 19,
    'commits_including_traps': 21, 'timer_window_retired': [9, 3],
    'observer_on_off_identical': True}, indent=2) + '\n')
print('PASS: 21 commits / 19 retired; timer windows 9 and 3; observer on/off identical')
