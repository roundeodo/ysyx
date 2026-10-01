#!/usr/bin/env python3
"""Explicit ablation; each configuration owns a frozen build and immutable logs."""
import argparse, subprocess
from pathlib import Path
NPC=Path(__file__).resolve().parents[2];root=NPC/'result/branch-v3'
CONFIGS={'SE0':['--choice','1','--early','1'],'R0-held':['--early-ras','1'],'ER0-held':['--early','1','--early-ras','1'],'NER0-held':['--direction','5','--early','1','--early-ras','1'],'NSmallER-held':['--direction','5','--tage-base','16','--tage-entries','8','--tage-tags','6','--tage-lengths','3','7','--early','1','--early-ras','1'],'B64':['--bht','64'],'G64':['--bht','64','--direction','1','--history','4'],'N0B32':['--direction','5','--btb','32'],'N0-spec-fixed':['--direction','5','--spec','1'],'NSmall':['--direction','5','--tage-base','16','--tage-entries','8','--tage-tags','6','--tage-lengths','3','7'],'NSmallER':['--direction','5','--tage-base','16','--tage-entries','8','--tage-tags','6','--tage-lengths','3','7','--early','1','--early-ras','1'],'R0':['--early-ras','1'],'ER0':['--early-ras','1','--early','1'],'NER0':['--direction','5','--early-ras','1','--early','1'],'H2-narrow-v2':['--choice','2'],'H2-narrow':['--choice','2'],'H2E-narrow':['--choice','2','--early','1'],'T16B32-valid':['--direction','4','--btb','32'],
         'N0':['--direction','5'],
         'NL-spec':['--direction','5','--loop','1','--spec','1'],
         'NS-spec':['--direction','5','--sc','1','--spec','1'],
         'NSL-spec':['--direction','5','--sc','1','--loop','1','--spec','1'], 'NL':['--direction','5','--loop','1'],
         'NS':['--direction','5','--sc','1'], 'NSL':['--direction','5','--sc','1','--loop','1'],
         'H2E':['--choice','2','--early','1'], 'N0E':['--direction','5','--early','1'],
         'B0-final-off':[]}
p=argparse.ArgumentParser();p.add_argument('names',nargs='+',choices=list(CONFIGS));a=p.parse_args()
for name in a.names:
    for action in ['build','run']:
        log=root/(action+'-'+name+'.log')
        with log.open('x') as f:
            subprocess.run(['python3',str(NPC/'tools/branch_v3/run_core.py'),action,'--name',name,*CONFIGS[name]],stdout=f,stderr=subprocess.STDOUT,check=True)
        print('PASS',action,name,flush=True)
