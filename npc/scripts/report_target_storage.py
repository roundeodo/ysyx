#!/usr/bin/env python3
"""Export compact, machine-readable target-storage evidence and source snapshots."""
import argparse
import csv
import json
import math
from pathlib import Path
import shutil
import tarfile
from explore_frontend import NPC, sha


def read(path): return json.loads(path.read_text())


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--root',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
    a=p.parse_args();root=a.root.resolve();out=a.output.resolve();assert read(root/'audit.json')['status']=='passed'
    out.mkdir(parents=True,exist_ok=False);dev=read(root/'development-summary.json');held=read(root/'held-summary.json');rows=[]
    traffic={};base={r['case']['name']:r for r in read(root/'rtl/dev-legal-common/B0/results.json')['results']}
    for name,x in dev['configurations'].items():
        rows.append({'name':name,'area_um2':x['ppa']['area_um2'],'legal_mhz':x['ppa']['mhz'],
                     'common_mhz':dev['common_mhz'],'common_time_ratio':x['common']['time_ratio_gm'],
                     'development_own_time_ratio':x['own']['time_ratio_gm'],'development_adp_ratio':x['own']['adp_ratio'],
                     'held_own_time_ratio':held[name]['time_ratio_gm'],'held_adp_ratio':held[name]['adp_ratio'],
                     'held_worst_input_ratio':held[name]['max_input_time_ratio']})
        family={}
        for r in read(root/'rtl/dev-legal-common'/name/'results.json')['results']:
            c=r['counters'];b=base[r['case']['name']]['counters'];f=family.setdefault(r['case']['kind'],{})
            values={'resolved_error_ratio':(c['conditional_errors']+c['target_errors'])/(b['conditional_errors']+b['target_errors']),
                    'btb_missing_ratio':c['btb_missing']/b['btb_missing'],'i_beats_ratio':c['i_beats']/b['i_beats']}
            for k,v in values.items():f.setdefault(k,[]).append(v)
        traffic[name]={k:math.exp(sum(sum(map(math.log,f[k]))/len(f[k]) for f in family.values())/len(family)) for k in next(iter(family.values()))}
    with (out/'comparison.csv').open('w') as f:
        w=csv.DictWriter(f,fieldnames=list(rows[0]));w.writeheader();w.writerows(rows)
    table=['|配置|面积 μm²|合法 MHz|同频时间|开发面积×时间|保留面积×时间|', '|---|---:|---:|---:|---:|---:|']
    for r in rows:table.append(f'|{r["name"]}|{r["area_um2"]:.3f}|{r["legal_mhz"]}|{(r["common_time_ratio"]-1)*100:+.3f}%|{(r["development_adp_ratio"]-1)*100:+.3f}%|{(r["held_adp_ratio"]-1)*100:+.3f}%|')
    (out/'comparison.md').write_text('\n'.join(table)+'\n')
    summary={'decision':read(root/'decision.json'),'comparison':rows,'traffic_at_common_clock':traffic,
             'sensitivity':read(root/'sensitivity.json'),'far_calls':read(root/'far-calls.json'),
             'microbench':{n:read(root/'microbench'/n/'report.json') for n in ['B0off','F16','U16','H32']},
             'limits':['RV32I edge-software proxies, not full model inference','pre-layout mapped area and STA; no measured power',
                       'Short-target bank boundaries can severely degrade unrepresented branch working sets',
                       'MicroBench test only; no new train result','720MHz initial matrix is functional diagnostic, not qualified for all candidates',
                       'Counter partitions describe observations, not isolated causal stall attribution']}
    (out/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    # Select results explicitly; do not copy huge synthesis netlist JSON or generated compiler sources.
    files=list(root.glob('*.json'))
    for pattern in ['images/manifest.json','images-reproduction/manifest.json','layouts/*/manifest.json','boundary-probe/manifest.json',
                    'rtl/*/*/results.json','ppa/*/*.json','builds/*/*.json','verification/*/manifest.json',
                    'verification/compact-btb-v2/results.json','verification/*/*/*/manifest.json','verification/*/exception/manifest.json',
                    'difftest/results.json','model*/results.json','target-observer/results.json','target-observer/build/manifest.json',
                    'references/manifest.json','microbench/*/report.json','microbench/*/manifest.json']:
        files+=list(root.glob(pattern))
    for path in sorted(set(files)):
        target=out/'evidence'/path.relative_to(root);target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(path,target)
    logs={}
    for path in root.rglob('*'):
        if path.is_file() and '.log' in path.name:logs[str(path.relative_to(root))]={'sha256':sha(path),'bytes':path.stat().st_size}
    archives={str(p.relative_to(root)):read(p) for p in (root/'ppa').glob('*/sta-archive.json')}
    (out/'raw-log-index.json').write_text(json.dumps({'root':str(root),'files':logs,'archived_sta':archives},indent=2)+'\n')
    with tarfile.open(out/'source-snapshots.tar.gz','w:gz') as t:
        for folder in ['baseline','candidate-source']:
            for path in (root/folder).rglob('*'):
                if path.is_file():t.add(path,arcname=str(path.relative_to(root)),recursive=False)
        for relative in read(root/'execution-sources.json'):
            t.add(NPC.parent/relative,arcname='execution-source/'+relative,recursive=False)
    with tarfile.open(out/'software-images.tar.gz','w:gz') as t:
        for folder in ['images','layouts','boundary-probe']:
            for path in (root/folder).rglob('*'):
                if path.is_file():t.add(path,arcname=str(path.relative_to(root)),recursive=False)
    (out/'README.md').write_text('''# 分支目标存储探索数据

开发与保留输入中U16小幅改善面积×时间；跨64 KiB调用退化，通用默认保持B0。
`summary.json`、`comparison.csv`给出结果；`evidence`保留配置、逐项测量、验证和资格检查。
`raw-log-index.json`绑定本机原始日志，包括失败尝试；STA原始文件以校验过的tar.gz保存。
`source-snapshots.tar.gz`含最初基线、实际RTL候选和最终执行脚本；`software-images.tar.gz`含软件输入。
复现入口为 `npc/scripts/reproduce_target_storage.py`；先执行 `--root <原始实验目录> --check-only`。
本目录不包含新的MicroBench train结果。
''')
    (out/'export-sha256.json').write_text(json.dumps({str(p.relative_to(out)):sha(p) for p in out.rglob('*') if p.is_file()},indent=2)+'\n')
    print('PASS target report export',out,flush=True)


if __name__=='__main__':main()
