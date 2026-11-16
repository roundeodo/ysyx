#!/usr/bin/env python3
"""Audit existing target evidence or rerun the fixed experiment into a fresh directory."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
from explore_frontend import NPC, sha


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root',type=Path,required=True,help='Completed original experiment with frozen source snapshots')
    p.add_argument('--output',type=Path,help='New directory for a full reproduction')
    p.add_argument('--check-only',action='store_true')
    a=p.parse_args();original=a.root.resolve()
    for relative,expected in json.loads((original/'execution-sources.json').read_text()).items():
        assert sha(NPC.parent/relative)==expected,relative
    if a.check_only:
        subprocess.run(['python3',str(NPC/'scripts/audit_target_storage.py'),'--root',str(original)],cwd=NPC.parent,check=True)
        return
    if a.output is None:p.error('Use --output for a full reproduction, or --check-only')
    out=a.output.resolve();out.mkdir(parents=True,exist_ok=False)
    for folder in ['baseline','candidate-source']:shutil.copytree(original/folder,out/folder)
    for file in ['baseline-manifest.json','configurations.json','candidate-plan.json','toolchain.json','execution-sources.json']:
        shutil.copy2(original/file,out/file)
    def run(label,script,*args):
        command=['python3',str(NPC/'scripts'/f'{script}.py'),*map(str,args)]
        with (out/(label+'.log')).open('x') as stream:
            stream.write(json.dumps(command)+'\n');stream.flush()
            subprocess.run(command,cwd=NPC.parent,stdout=stream,stderr=subprocess.STDOUT,check=True)
        print('PASS',label,flush=True)
    for folder in ['images','images-reproduction']:
        run('build-'+folder,'build_branch_workloads','--output',out/folder,'--held-seeds',2053,4099)
    run('image-reproduction','check_target_images','--root',out)
    run('layout-build','build_target_layouts','--root',out)
    run('model-tests','test_target_model')
    run('measurement-tests','test_branch_measurement')
    run('unit-test','test_compact_btb','--root',out,'--label','compact-btb-v2')
    run('development','run_target_development','--root',out)
    run('model','model_target_storage','--root',out,'--trace-root',out/'rtl/dev-common/B0','--label','model-strong')
    run('observer','observe_target_misses','--root',out,'--reference',out/'rtl/dev-common/B0/results.json')
    run('safety','verify_branch','--root',out,'--target-study','--configs','B0off','F16','U16','U32W4','H32')
    run('difftest','verify_direction_difftest','--root',out,'--target-study','--configs','F16','U16','U32W4','H32')
    names=list(json.loads((out/'configurations.json').read_text()))
    run('ppa-queue','run_target_ppa','--root',out,'--configs',*names)
    run('qualified-development','evaluate_target_storage','development','--root',out)
    run('held-evaluation','evaluate_target_storage','held','--root',out)
    run('far-calls','test_target_far_calls','--root',out)
    run('microbench','run_target_microbench','--root',out)
    run('audit','audit_target_storage','--root',out)
    run('report','report_target_storage','--root',out,'--output',out/'report')
    print('PASS full reproduction; train was not run',out,flush=True)


if __name__=='__main__':main()
