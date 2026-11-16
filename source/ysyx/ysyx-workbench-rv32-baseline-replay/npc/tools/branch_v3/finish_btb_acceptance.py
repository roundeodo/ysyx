#!/usr/bin/env python3
"""Finish the declared validation matrix, freeze once, then execute the holdout."""
import subprocess
import sys
import time

from run_btb_matrix import ROOT, TOOL
from run_large_btb_matrix import POINTS


def invoke(script):
    subprocess.run([sys.executable, str(TOOL/script)], check=True)


required = []
for name, (_, mhz) in POINTS.items():
    for tail in ['', '-validation']:
        required.append(ROOT/'rtl'/f'{name}-paired-long-{mhz}{tail}'/'index.json')
while any(not path.exists() for path in required):
    time.sleep(10)
invoke('check_paired_windows.py')
invoke('summarize_btb.py')
invoke('freeze_selection.py')
invoke('run_final.py')
invoke('summarize_final.py')
