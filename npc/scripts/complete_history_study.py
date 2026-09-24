#!/usr/bin/env python3
"""Finalize existing background runs only after all required evidence is complete."""
import argparse
import json
from pathlib import Path
import subprocess
import time
from explore_frontend import NPC,sha
from buffer_history_training import PARENTS


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--root',type=Path,required=True)
    root=p.parse_args().root.resolve()
    needed=['comparison.json','microbench/B0I/report.json','microbench/T16/report.json']
    while any(not (root/x).exists() for x in needed):
        for name in ['finish.log','microbench.log','buffer-controls.log',*[f'ppa-{name}.log' for name in ['B0I','B512','G256','G512','T16','T32',*PARENTS]]]:
            path=root/name
            if path.exists():
                with path.open('rb') as f:
                    f.seek(max(0,path.stat().st_size-3000));tail=f.read()
                if b'Traceback (most recent call last)' in tail:
                    raise RuntimeError(f'Background step failed; preserve logs and resume after repair: {path}')
        time.sleep(10)
    for name in ['B0I','T16']:
        report=json.loads((root/f'microbench/{name}/report.json').read_text())
        ppa=json.loads((root/f'ppa/{name}/qualified.json').read_text())
        assert report['cpu_mhz']<=ppa['mhz'],f'{name}: MicroBench frequency needs a qualified rerun'
    for label,script in [('audit','audit_history_study'),('report-export','report_history_study')]:
        with (root/(label+'.log')).open('w') as f:
            subprocess.run(['python3',str(NPC/'scripts'/f'{script}.py'),'--root',str(root)],
                           stdout=f,stderr=subprocess.STDOUT,check=True)
    path=NPC/'docs/verification/BRANCH_HISTORY_EXPLORATION_2026-09-24.md';text=path.read_text()
    text=text.replace('本轮进行中，默认配置不变。','本轮测量、完整STA和保留输入比较已完成，默认配置不变。')
    text=text.replace('## 新候选的开发结果（尚待完整频点比较）','## 开发筛选记录（720 MHz诊断）')
    text=text.replace('其独立PPA仍在进行，以隔离公共代码和映射变化。','其独立PPA与映射差别见最终比较表。')
    link='[最终比较、保留集与复现命令](data/branch-history-20260924/README.md)'
    if link not in text:text=text.replace('\n\n','\n\n'+link+'。下文保留各阶段测量与修正依据，最终选型以该表为准。\n\n',1)
    path.write_text(text)
    (root/'completion.json').write_text(json.dumps({'status':'passed','audit_sha256':sha(root/'audit.json'),
        'comparison_sha256':sha(root/'comparison.json'),'report':str(NPC/'docs/verification/data/branch-history-20260924/README.md'),
        'remote_changed':False,'default_changed':False},indent=2)+'\n')
    print('PASS complete study, compact report and evidence audit',flush=True)

if __name__=='__main__':main()
