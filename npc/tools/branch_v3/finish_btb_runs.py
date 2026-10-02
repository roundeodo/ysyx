#!/usr/bin/env python3
"""One additional build queue; wait for the recorded initial queue to finish."""
import argparse,subprocess,sys,time
from pathlib import Path
NPC=Path(__file__).resolve().parents[2];ROOT=NPC/'result/branch-v3';TOOL=Path(__file__).resolve().parent
p=argparse.ArgumentParser();p.add_argument('action',choices=['ppa','verification','long']);a=p.parse_args()
def wait_for(path):
 while not path.exists():time.sleep(10)
def run(script,*args):subprocess.run([sys.executable,str(TOOL/script),*args],check=True)
if a.action=='ppa':
 wait_for(ROOT/'ppa/BT64-select/qualified.json')
 run('run_btb_matrix.py','ppa','BT16-admit','BT16-rrip-all','BT16-rrip','BT16-fold','BT16-way4','BT16-way4-rrip')
 run('run_btb_extended.py','ppa','TAGE-BT16','TAGE-BT32','TAGE-BT64','TAGE-BT64-base','NSL-BT64','EARLY-BT16','TAGE-EARLY-BT16')
elif a.action=='verification':
 wait_for(ROOT/'rtl/TAGE-EARLY-BT16-streams/index.json')
 run('test_btb.py')
 run('run_difftest.py','BT64-select','TAGE-BT64','NSL-BT64','TAGE-EARLY-BT16')
 run('run_safety.py','TAGE-BT64','NSL-BT64','TAGE-EARLY-BT16')
else:
 wait_for(ROOT/'rtl/TAGE-EARLY-BT16-streams/index.json')
 wait_for(ROOT/'rtl/BT0-long-long/index.json')
 run('run_btb_extended.py','long','BT16-select-long','BT32-select-long','BT64-select-long','TAGE-long','TAGE-BT64')
