#!/usr/bin/env python3
"""Re-run closed-loop cycles at legal frequencies; do not merely rescale old cycles."""
import json,subprocess,time
from pathlib import Path
NPC=Path(__file__).resolve().parents[2];r=NPC/'result/branch-v3'
# Each binary is the actual measured algorithm. Snapshots/manifests bind its sources.
candidates={'B0off':'B0-final-off','H2':'H2','E0':'E0','N0-widthfix':'N0','N0E':'N0E','B32':'B32'}
while any(not (r/'ppa'/p/'qualified.json').exists() for p in candidates):
    time.sleep(10)
frequencies={name:json.loads((r/'ppa'/name/'qualified.json').read_text())['mhz'] for name in candidates}
common=min(frequencies.values())
(r/'legal-frequency-plan.json').write_text(json.dumps({'common_mhz':common,'own_mhz':frequencies,'binaries':candidates},indent=2)+'\n')
for name,binary in candidates.items():
    for mhz in sorted(set([common,frequencies[name]])):
        for images in ['images','real-images']:
            label=f'{name}-{mhz}MHz-'+('proxy' if images=='images' else 'real')
            command=['python3',str(NPC/'tools/branch_v3/run_core.py'),'run','--name',binary,'--label',label,'--mhz',str(mhz),'--images',str(r/images)]
            with (r/(label+'.log')).open('x') as log:subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,check=True)
            print('PASS legal frequency',label,flush=True)
