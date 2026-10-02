#!/usr/bin/env python3
"""Same executable stream with two passive measurement starts; no train/holdout."""
import argparse,subprocess,sys
from pathlib import Path
NPC=Path(__file__).resolve().parents[2];ROOT=NPC/'result/branch-v3';TOOL=Path(__file__).resolve().parent
p=argparse.ArgumentParser();p.add_argument('name');p.add_argument('--mhz',type=int,default=700)
p.add_argument('--split',choices=['development','validation'],default='development');a=p.parse_args()
label=f'{a.name}-paired-long-{a.mhz}'+('-validation' if a.split=='validation' else '')
if not (ROOT/'rtl'/label/'index.json').exists():
 command=[sys.executable,str(TOOL/'run_core.py'),'run','--name',a.name,'--label',label,'--images',str(ROOT/f'streams-long-paired-{a.split}'),'--compact','--branch-window','8192','--max-cycles','200000000','--mhz',str(a.mhz)]
 for kind in ('jsmn','miniz'):
  for window in ('cold','warm'):command+=['--case',f'{kind}_long-128-{window}']
 subprocess.run(command,check=True)
