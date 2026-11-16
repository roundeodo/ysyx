#!/usr/bin/env python3
"""Run fresh physical-latency simulations at each configuration's qualified clock."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import shutil
import subprocess
import time
from explore_frontend import sha


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--root',type=Path,required=True)
    p.add_argument('--configs',nargs='+',required=True);a=p.parse_args();root=a.root.resolve()
    def run(name):
        deadline=time.monotonic()+4*3600
        qualified=root/'ppa'/name/'qualified.json'
        while not qualified.exists():
            if time.monotonic()>deadline:raise RuntimeError('PPA deadline: '+name)
            time.sleep(10)
        mhz=json.loads(qualified.read_text())['mhz']
        common=root/'rtl/dev-common'/name/'results.json'
        while not common.exists() or len(json.loads(common.read_text())['results'])!=10:
            if time.monotonic()>deadline:raise RuntimeError('Common clock deadline: '+name)
            time.sleep(10)
        out=root/'rtl/dev-own'/name
        if mhz==660:
            out.mkdir(parents=True,exist_ok=False)
            shutil.copy2(common,out/'results.json')
            (out/'reused.json').write_text(json.dumps({'original':str(common),'sha256':sha(common),
                'reason':'qualified clock equals measured common clock; binary/images/physical memory model identical'},indent=2)+'\n')
        else:
            subprocess.run(['python3','npc/scripts/followup_branch.py','run','--root',str(root),
                '--config',name,'--mhz',str(mhz),'--label','dev-own'],check=True)
        rows=json.loads((out/'results.json').read_text())['results']
        references={row['case']['name']:row for row in json.loads((root/'rtl/dev-common/B0/results.json').read_text())['results']}
        for row in rows:
            for key in ['retired','all_retired','digest','checksum']:
                assert row['result'][key]==references[row['case']['name']]['result'][key],(name,row['case']['name'],key)
        print('OWN CLOCK PASS',name,mhz,flush=True)
    # Waiters do not prevent already-qualified configurations from running.
    order=sorted(a.configs,key=lambda n:not (root/'ppa'/n/'qualified.json').exists())
    with ThreadPoolExecutor(max_workers=2) as pool:list(pool.map(run,order))
    (root/'own-clock-complete.json').write_text(json.dumps({'configs':a.configs},indent=2)+'\n')


if __name__=='__main__':main()
