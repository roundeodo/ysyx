#!/usr/bin/env python3
"""Audit retained evidence or rebuild the frozen history experiment in a new folder."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
from explore_frontend import NPC,sha
from finish_history_study import NAMES
from buffer_history_training import PARENTS


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--root',type=Path,required=True)
    p.add_argument('--output',type=Path);p.add_argument('--check-only',action='store_true')
    p.add_argument('--partial',action='store_true',help='Report pending evidence during an ongoing run')
    a=p.parse_args();original=a.root.resolve()
    if a.check_only:
        command=['python3',str(NPC/'scripts/audit_history_study.py'),'--root',str(original)]
        if a.partial:command.append('--partial')
        subprocess.run(command,check=True);return
    if a.output is None:p.error('--output is required for a full reproduction')
    for path,value in json.loads((original/'tool-bindings.json').read_text()).items():
        assert sha(Path(path))==value,path
    recorded=json.loads((original/'execution-sources.json').read_text())
    for path,value in recorded.items():assert sha(NPC.parent/path)==value,path
    out=a.output.resolve();out.mkdir(parents=True,exist_ok=False)
    for folder in ['baseline','candidate-source']:shutil.copytree(original/folder,out/folder)
    for name in ['manifest.json','configurations.json','candidate-hashes.json','execution-sources.json','tool-bindings.json']:
        shutil.copy2(original/name,out/name)
    def run(label,script,*arguments):
        command=['python3',str(NPC/'scripts'/f'{script}.py'),*map(str,arguments)]
        with (out/(label+'.log')).open('x') as f:
            f.write(json.dumps(command)+'\n');f.flush()
            subprocess.run(command,cwd=NPC.parent,stdout=f,stderr=subprocess.STDOUT,check=True)
        print('PASS',label,flush=True)
    run('images','build_branch_workloads','--output',out/'images','--dev-seeds',331,733,'--held-seeds',1597,3253)
    expected={x['name']:x for x in json.loads((original/'images/manifest.json').read_text())['cases']}
    for case in json.loads((out/'images/manifest.json').read_text())['cases']:
        ref=expected[case['name']]
        for key in ['expected','begin_pc','end_pc']:assert case[key]==ref[key]
        # ELF FILE symbols can include a temporary compiler name; loaded BIN must match.
        assert case['hashes']['image.bin']==ref['hashes']['image.bin']
    (out/'build-map.json').write_text(json.dumps(PARENTS,indent=2)+'\n')
    for name in NAMES:
        if name not in PARENTS:run('build-'+name,'explore_history','build','--root',out,'--config',name)
        options=['--trace'] if name=='B0' else []
        run('dev-'+name,'explore_history','run','--root',out,'--config',name,*options)
    b0=json.loads((out/'rtl/dev-common/B0/results.json').read_text())['results']
    b0i=json.loads((out/'rtl/dev-common/B0I/results.json').read_text())['results']
    assert all(x['result']==y['result'] and x['counters']==y['counters'] for x,y in zip(b0,b0i))
    (out/'infrastructure-parity.json').write_text(json.dumps({'status':'passed','cases':len(b0)})+'\n')
    run('model-tests','test_history_model');run('history-timing-tests','test_history_timing')
    run('model','model_history','--root',out);run('model-parity','test_history_cpp','--root',out)
    run('history-model','model_history_timing','--root',out)
    run('tage-tests','test_tage_rtl','--output',out/'tage-tests')
    run('legacy-direction-tests','test_direction_rtl','--output',out/'legacy-direction-tests')
    run('memory-audit','test_reference_memory','--output',out/'memory-audit')
    for name in ['B0','T16']:run('observer-'+name,'observe_history_recovery','--root',out,'--config',name)
    run('penalty-audit','audit_branch_penalty','--root',out)
    run('timing-summary','summarize_history_audit','--root',out)
    run('correlation','test_history_correlation','--root',out)
    run('safety','verify_branch','--root',out,'--direction-study','--configs','T16','T32')
    run('difftest','verify_direction_difftest','--root',out,'--configs','T16','T32')
    run('buffer-unit','test_training_buffers')
    for name in NAMES:run('ppa-'+name,'explore_history','ppa','--root',out,'--config',name)
    run('buffer-noop','buffer_history_training','--root',out,'--check-noop','B0I','T16','T32')
    run('comparisons','finish_history_study','--root',out)
    selected=json.loads((out/'selection-freeze.json').read_text())
    names=list(dict.fromkeys(['B0',selected['simple_comparator'],selected['tage_comparator'],'G512F']))
    common_mhz=min(selected['ppa'][n]['mhz'] for n in names)
    for name in names:
        label=f'dev-own-{common_mhz}'
        if not (out/'rtl'/label/name/'results.json').exists():
            run('practical-common-'+name,'explore_history','run','--root',out,'--config',name,
                '--label',label,'--mhz',common_mhz,'--latency-ns',100)
    micro_mhz=min(json.loads((out/'ppa'/n/'qualified.json').read_text())['mhz'] for n in ['B0I','T16'])
    for name,policy,history in [('B0I',0,4),('T16',3,16)]:
        run('microbench-'+name,'run_microbench_perf','--scale','test','--cpu-mhz',micro_mhz,
            '--output',out/'microbench'/name,'--icache-bytes',1024,'--icache-ways',4,
            '--icache-line',32,'--icache-policy',13,'--bht-entries',16,'--btb-entries',16,
            '--btb-ways',2,'--btb-policy',0,'--ras-entries',4,'--direction-policy',policy,
            '--history-bits',history,'--host-opt',2,'--verify-observer')
    run('audit','audit_history_study','--root',out)
    print('PASS full reproduction; train was not run',out,flush=True)

if __name__=='__main__':main()
