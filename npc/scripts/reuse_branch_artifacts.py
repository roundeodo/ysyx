#!/usr/bin/env python3
"""Reuse exact source-matched frozen target-policy artifacts on fresh inputs."""
import argparse
import json
from pathlib import Path
import shutil
from explore_frontend import sha


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root',type=Path,required=True);p.add_argument('--previous',type=Path,required=True)
    p.add_argument('--configs',nargs='+',choices=['S32','A32','R32'],required=True)
    a=p.parse_args();root=a.root.resolve();old=a.previous.resolve()
    config=json.loads((root/'configurations.json').read_text())
    for name in a.configs:
        original=old/'builds'/name;manifest=json.loads((original/'manifest.json').read_text())
        for filename,digest in manifest['sources'].items():
            relative='npc/'+filename.rsplit('/npc/',1)[1]
            assert sha(root/'baseline'/relative)==digest,relative
        c={'bht':64,'btb':32,'target_policy':{'S32':0,'A32':1,'R32':2}[name]}
        assert '+define+YSYX_BRANCH_TARGET_POLICY='+str(c['target_policy']) in manifest['command']
        dest=root/'builds'/name
        if dest.exists():
            assert sha(dest/'obj/Vexploration_core_tb')==sha(original/'obj/Vexploration_core_tb')
        else:
            (dest/'obj').mkdir(parents=True)
            shutil.copy2(original/'obj/Vexploration_core_tb',dest/'obj/Vexploration_core_tb')
            shutil.copy2(original/'manifest.json',dest/'manifest.json')
            (dest/'config.json').write_text(json.dumps(c,indent=2)+'\n')
            (dest/'reused.json').write_text(json.dumps({'original':str(original),'binary_sha256':sha(dest/'obj/Vexploration_core_tb'),
                'validation':'all compiled source hashes match followup baseline, including memory and observer'},indent=2)+'\n')
        config[name]=c
        original=old/'ppa'/name;dest=root/'ppa'/name
        for relative,digest in json.loads((original/'source-hashes.json').read_text()).items():
            assert sha(root/'baseline'/relative)==digest,relative
        dest.mkdir(exist_ok=False)
        files=['qualified.json','cells.json','timing.json','source-hashes.json','command.json']
        for filename in files:shutil.copy2(original/filename,dest/filename)
        (dest/'reused.json').write_text(json.dumps({'original':str(original),'records':{n:sha(original/n) for n in files},
            'validation':'all compiled RTL sources match frozen baseline; same original AREA3/820MHz/NanGate45 flow; original logs retained'},indent=2)+'\n')
    (root/'configurations.json').write_text(json.dumps(config,indent=2)+'\n')


if __name__=='__main__':main()
