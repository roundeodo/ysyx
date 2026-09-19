#!/usr/bin/env python3
"""Check the frozen mapped netlist at a lower clock without resynthesis."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

out = Path(__file__).resolve().parent
root = out.parents[3]
mhz = int(sys.argv[1])
source = out / 'sta/riscv32_core_reset_boundary-820MHz-buffered'
target = out / f'sta/riscv32_core_reset_boundary-{mhz}MHz-buffered'
target.mkdir()
for name in ['riscv32_core_reset_boundary.netlist.v', 'constraints.sdc']:
    shutil.copy2(source / name, target / name)
tool = root / 'npc/result/sta/rv32-interrupt-20260906/toolflow'
netlist = target / 'riscv32_core_reset_boundary.netlist.v'
command = [str(tool / 'bin/iEDA'), '-script', str(tool / 'scripts/sta.tcl'),
           str(target / 'constraints.sdc'), str(netlist), 'riscv32_core_reset_boundary', 'nangate45']
(target / 'command.json').write_text(json.dumps({'command': command, 'clock_mhz': mhz,
    'netlist_sha256': hashlib.sha256(netlist.read_bytes()).hexdigest(),
    'same_netlist_as_820mhz': True}, indent=2) + '\n')
env = dict(os.environ, NPC_HOME=str(root / 'npc'), AM_HOME=str(root / 'abstract-machine'),
           NEMU_HOME=str(root / 'nemu'), NPC_STA_NETLIST_FILE=str(netlist),
           CLK_FREQ_MHZ=str(mhz), RUN_POWER_ANALYSIS='0')
with (target / 'sta.log').open('w') as log:
    result = subprocess.run(command, cwd=tool, env=env, stdout=log, stderr=subprocess.STDOUT)
(target / 'sta.exit').write_text(str(result.returncode) + '\n')
if result.returncode:
    raise SystemExit(result.returncode)
spec = importlib.util.spec_from_file_location('compare',
    out.parent / 'rv32-readability-ppa-20260919/compare.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
timing = module.timing(target)
(target / 'timing.json').write_text(json.dumps(timing, indent=2) + '\n')
print(json.dumps(timing, indent=2))
assert all(group['slack_ns'] >= 0 for group in timing.values()), 'Timing does not close'
