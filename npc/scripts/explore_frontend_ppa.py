#!/usr/bin/env python3
"""Freeze each configuration, synthesize serially, qualify all STA groups."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
NPC = ROOT / 'npc'
FLOW = NPC / 'result/sta/rv32-interrupt-20260906/toolflow'
CONFIGS = {'B0': (256,1,0), 'B1': (256,2,0), 'B2': (256,2,1),
           'B3': (256,2,2), 'C': (256,2,3), 'capacity': (512,1,0), 'line32': (256,1,0)}


def execute(command, cwd, env, log):
    with log.open('w') as stream:
        result = subprocess.run(command, cwd=cwd, env=env, stdout=stream, stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError(f'{log}: exit {result.returncode}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--configs', nargs='+', choices=list(CONFIGS), default=list(CONFIGS))
    args = parser.parse_args()
    args.output = args.output.resolve()
    spec = importlib.util.spec_from_file_location('sta_parser', NPC / 'result/performance/rv32-readability-ppa-20260919/compare.py')
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    env = dict(os.environ, NPC_HOME=str(NPC), AM_HOME=str(ROOT/'abstract-machine'), NEMU_HOME=str(ROOT/'nemu'))
    for name in args.configs:
        out = args.output/name
        out.mkdir(parents=True, exist_ok=False)
        source = out/'source'
        files = [Path(row.replace('${NPC_HOME}',str(NPC))) for row in
                 (NPC/'vsrc/riscv32/filelist/filelist_sta.f').read_text().splitlines() if row.startswith('${NPC_HOME}')]
        hashes = {}
        for path in files:
            relative = path.relative_to(ROOT)
            target = source/relative
            target.parent.mkdir(parents=True,exist_ok=True)
            shutil.copy2(path,target)
            hashes[str(relative)] = hashlib.sha256(path.read_bytes()).hexdigest()
        (out/'source-hashes.json').write_text(json.dumps(hashes,indent=2)+'\n')
        capacity,ways,policy = CONFIGS[name]
        command = ['make','-C','npc','git_commit=','NPC_CONFIG=rv32-baseline','sta-reset',
                   'STA_FREQUENCY_MHZ=820','STA_SYNTH_STRATEGY=AREA 3',f'STA_TOOL_DIR={FLOW}',
                   f'STA_OUTPUT_ROOT={out/"sta"}',f'NPC_ICACHE_CAPACITY_BYTES={capacity}',
                   f'NPC_ICACHE_WAY_COUNT={ways}',f'NPC_ICACHE_REPLACEMENT_POLICY={policy}',
                   f'NPC_ICACHE_LINE_BYTES={32 if name == "line32" else 16}',
                   'STA_RTL_DEPENDENCIES='+' '.join(str(source/p.relative_to(ROOT)) for p in files)]
        (out/'command.json').write_text(json.dumps(command,indent=2)+'\n')
        print('SYNTH',name,flush=True)
        execute(command,ROOT,env,out/'synthesis.log')
        mapped = out/'sta/riscv32_core_reset_boundary-820MHz-buffered'
        results = {}
        for mhz in [580,560,540,520,500,480]:
            target = out/f'sta/riscv32_core_reset_boundary-{mhz}MHz-buffered'
            target.mkdir()
            for f in ['riscv32_core_reset_boundary.netlist.v','constraints.sdc']:
                shutil.copy2(mapped/f,target/f)
            netlist = target/'riscv32_core_reset_boundary.netlist.v'
            command = [str(FLOW/'bin/iEDA'),'-script',str(FLOW/'scripts/sta.tcl'),
                       str(target/'constraints.sdc'),str(netlist),'riscv32_core_reset_boundary','nangate45']
            run_env = dict(env,NPC_STA_NETLIST_FILE=str(netlist),CLK_FREQ_MHZ=str(mhz),RUN_POWER_ANALYSIS='0')
            execute(command,FLOW,run_env,target/'sta.log')
            timing = helper.timing(target)
            violations=(target/'riscv32_core_reset_boundary.rpt').read_text().count('slack (VIOLATED)')
            passed=not violations and all(g['slack_ns']>=0 for g in timing.values())
            results[str(mhz)]={'groups':timing,'violations':violations,'passed':passed}
            (out/'timing.json').write_text(json.dumps(results,indent=2)+'\n')
            if passed:
                print('STA PASS',name,mhz,flush=True)
                break
        else:
            raise RuntimeError(f'{name} did not meet any qualification point')


if __name__ == '__main__': main()
