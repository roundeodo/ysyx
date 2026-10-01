#!/usr/bin/env python3
"""Closed-loop diagnostic only: disable or perfectly supply the next-PC result."""
import argparse
import ast
import hashlib
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

NPC=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(NPC/'scripts'))
import explore_frontend as experiment
from followup_branch import defines
ROOT=NPC/'result/branch-v3'
parser=argparse.ArgumentParser();parser.add_argument('--name',default='oracle-diagnostic');args=parser.parse_args()
OUT=ROOT/args.name
OUT.mkdir(exist_ok=False)
source=OUT/'source'
shutil.copytree(NPC/'vsrc/riscv32',source/'rtl')
(source/'tests').mkdir()
for filename in ['core_tb.sv','axi_memory.sv']:
    shutil.copyfile(NPC/'tests/branch_v3'/filename,source/'tests'/filename)
# The existing diagnostic supplies no CPU state or outcomes: only predicted PC.
# Reuse its literal diagnostic block; bind its implementation hash in the manifest.
helper=NPC/'scripts/build_prediction_diagnostic.py'
tree=ast.parse(helper.read_text())
blocks={}
for node in ast.walk(tree):
    if isinstance(node,ast.Assign) and len(node.targets)==1 and isinstance(node.targets[0],ast.Name):
        if node.targets[0].id in ('extra','override') and isinstance(node.value,ast.Constant):
            blocks[node.targets[0].id]=node.value.value
assert set(blocks)=={'extra','override'}
path=source/'rtl/core/frontend/riscv32_branch_predictor.sv'
text=path.read_text()
anchor='  // 3. 预测选择：BTB 决定指令种类，BHT 决定条件分支方向，RAS 提供返回目标。'
assert anchor in text
text=text.replace(anchor,blocks['extra']+anchor)
anchor="    selected_prediction                  = '0;"
assert anchor in text
text=text.replace(anchor,blocks['override']+anchor)
path.write_text(text)
(OUT/'contract.json').write_text(json.dumps({'scope':'diagnostic; never synthesize; no claim of realizable zero-latency perfect predictor',
    'source_helper':str(helper),'helper_sha256':experiment.sha(helper),
    'modes':{'0':'same baseline','1':'always sequential, including jumps','2':'future dynamic architectural next PC'},
    'limits':'not a strict time upper bound because cache/interconnect interactions can be nonmonotonic'},indent=2)+'\n')
experiment.TEST=source/'tests'
experiment.build_rtl(OUT/'build',source/'rtl',defines({}),host_opt=1)
results=[]
for case in json.loads((ROOT/'rtl/B0-final-off/index.json').read_text()):
    name=case['name'];events=ROOT/'rtl/B0-final-off'/(name+'.events')
    pcs=[line.split(',')[3] for line in events.open() if line.startswith('C,')]
    assert len(pcs)>2, 'Baseline must contain full C events, not only ROI trace'
    oracle=OUT/(name+'.oracle');oracle.write_text('\n'.join(pcs)+'\n')
    baseline=(ROOT/'rtl/B0-final-off'/(name+'.log')).read_text()
    def values(text):
        line=next(line for line in text.splitlines() if line.startswith('RESULT '))
        return dict(re.findall(r'(\w+)=(\w+)',line))
    reference=values(baseline)
    for mode in [0,1,2]:
        folder=OUT/f'mode{mode}';folder.mkdir(exist_ok=True)
        command=[str(OUT/'build/obj/Vexploration_core_tb'),*[x for x in case['command'][1:] if not x.startswith(('+events=','+trace='))],
                 f'+prediction_mode={mode}',f'+oracle={oracle}',f'+oracle_count={len(pcs)}',f'+trace={folder/(name+".trace")}']
        log=folder/(name+'.log')
        with log.open('x') as output:subprocess.run(command,stdout=output,stderr=subprocess.STDOUT,check=True)
        text=log.read_text();assert 'PASS proxy' in text
        measured=values(text)
        for field in ['retired','all_retired','digest','checksum']:assert measured[field]==reference[field],(name,mode,field)
        if mode==0:assert measured==reference
        def retired_hash(file):
            digest=hashlib.sha256()
            for line in file.open():digest.update((','.join(line.split(',')[:3])+'\n').encode())
            return digest.hexdigest()
        assert retired_hash(folder/(name+'.trace'))==retired_hash(ROOT/'rtl/B0-final-off'/(name+'.trace'))
        results.append({'case':name,'mode':mode,'values':measured,'baseline':reference,'command':command,'oracle_sha256':experiment.sha(oracle),'log_sha256':experiment.sha(log)})
        (OUT/'results.json').write_text(json.dumps(results,indent=2)+'\n')
        print('PASS diagnostic',name,mode,measured['cycles'],flush=True)
