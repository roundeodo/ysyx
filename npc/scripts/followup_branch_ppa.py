#!/usr/bin/env python3
"""Same whole-core AREA3 mapping and four-group STA grid as the frozen experiment."""
import argparse
import fcntl
import json
from pathlib import Path
from followup_branch import defines
from select_icache_ppa import qualify


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root',type=Path,required=True);p.add_argument('--configs',nargs='+',required=True)
    p.add_argument('--resume',action='store_true');a=p.parse_args();root=a.root.resolve()
    cs=json.loads((root/'configurations.json').read_text());(root/'ppa').mkdir(exist_ok=True)
    for name in a.configs:
        c=cs[name];cache=c.get('icache',[1024,4,32,13])
        source=root/('baseline' if name in ['B0','O0','S32','A32','R32'] else 'candidate-source')
        overrides=[s.replace('YSYX_','NPC_',1) for s in defines(c)]
        with (root/'ppa'/('.'+name+'.lock')).open('a') as lock:
            fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            qualify(name,root/'ppa',a.resume,cache_config=(cache[0],cache[1],cache[3],cache[2]),extra_make=overrides,source_root=source)


if __name__=='__main__':main()
