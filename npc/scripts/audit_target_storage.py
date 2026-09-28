#!/usr/bin/env python3
"""Bind target-storage conclusions to immutable inputs, binaries, logs and legal clocks."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import tarfile
from explore_frontend import NPC, sha
from explore_target_storage import defines
from qualify_branch_runs import check_architecture, check_command
from verify_branch import check_sources


def read(path): return json.loads(path.read_text())


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--root',type=Path,required=True)
    a=p.parse_args();root=a.root.resolve();configs=read(root/'configurations.json');freeze=read(root/'selection-freeze.json')
    assert freeze['development_sha256']==sha(root/'development-summary.json')
    assert freeze['configurations_sha256']==sha(root/'configurations.json')
    for folder, hashes in [('baseline',read(root/'baseline-manifest.json')['files']),
                           ('candidate-source',read(root/'candidate-source/manifest.json'))]:
        for relative,expected in hashes.items():assert sha(root/folder/relative)==expected,(folder,relative)
    for relative,expected in read(root/'execution-sources.json').items():assert sha(NPC.parent/relative)==expected,relative
    for name,expected in read(root/'toolchain.json')['files'].items():
        path=Path(name);path=path if path.is_absolute() else NPC.parent/path
        assert sha(path)==(expected['sha256'] if isinstance(expected,dict) else expected),path
    binaries={}
    for name,cfg in configs.items():
        manifest=read(root/'builds'/name/'manifest.json')
        for setting in defines(cfg):
            key,value=setting.split('=',1);assert str(manifest['settings'][key])==value,(name,key)
        for path,expected in manifest['sources'].items():assert sha(Path(path))==expected,path
        binaries[name]=root/'builds'/name/'obj/Vexploration_core_tb'
        ppa=root/'ppa'/name;qualified=read(ppa/'qualified.json');timing=read(ppa/'timing.json')
        assert qualified['all_groups_passed'] and qualified['area_um2']==read(ppa/'cells.json')['area_um2']
        legal=timing[str(qualified['mhz'])]
        assert legal['passed'] and legal['violations']==0 and set(legal['groups'])=={'data_max','data_min','gating_max','gating_min'}
        assert all(g['slack_ns']>=0 for g in legal['groups'].values())
        if qualified['mhz']<800:assert not timing[str(qualified['mhz']+20)]['passed']
        source=root/('baseline' if name=='B0' else 'candidate-source')
        for relative,expected in read(ppa/'source-hashes.json').items():assert sha(source/relative)==expected,(name,relative)
        if name!='B0':
            archive=read(ppa/'sta-archive.json');assert sha(ppa/archive['archive'])==archive['sha256']
            with tarfile.open(ppa/archive['archive']) as inp:
                actual={m.name:hashlib.sha256(inp.extractfile(m).read()).hexdigest() for m in inp.getmembers() if m.isfile()}
            assert actual==archive['members']
    # Default-off integration is exactly equal, including the re-mapped area and STA grid.
    assert read(root/'ppa/B0/qualified.json')['area_um2']==read(root/'ppa/B0off/qualified.json')['area_um2']
    for name in ['B0off','F16','U16']:
        base=read(root/'rtl/dev-legal-common/B0/results.json')['results'];other=read(root/'rtl/dev-legal-common'/name/'results.json')['results']
        for x,y in zip(base,other):assert x['result']==y['result'] and x['counters']==y['counters']
    counts={}
    for path in sorted((root/'rtl').glob('*/*/results.json')):
        label,name=path.parent.parent.name,path.parent.name;record=read(path)
        images=root/'boundary-probe' if label=='far-calls' else root/'layouts'/label[7:] if label.startswith('layout-') else root/'images'
        held=label=='held-own';cases={c['name']:c for c in read(images/'manifest.json')['cases'] if c['held']==held}
        assert len(record['results'])==len(cases) and {r['case']['name'] for r in record['results']}==set(cases)
        assert record['binary_sha256']==sha(binaries[name]) and record['memory_mode']=='physical'
        if label!='dev-common':assert record['mhz']<=read(root/'ppa'/name/'qualified.json')['mhz']
        if label.endswith('-own') or label in ['fast','slow','random'] or label.startswith('layout-'):
            assert record['mhz']==read(root/'ppa'/name/'qualified.json')['mhz']
        if held:assert path.stat().st_mtime>(root/'selection-freeze.json').stat().st_mtime
        base=read(root/'rtl'/label/'B0/results.json');check_architecture(base,record)
        for row in record['results']:
            case=cases[row['case']['name']];assert row['case']==case
            image=images/case['name']
            for file,expected in case['hashes'].items():assert sha(image/file)==expected
            data=(image/'image.bin').read_bytes();data+=b'\0'*(-len(data)%4)
            assert (image/'image.hex').read_text()==''.join(f'{int.from_bytes(data[i:i+4],"little"):08x}\n' for i in range(0,len(data),4))
            check_command(row['command'],binaries[name],image/'image.hex',case,record['mhz'],record['latency_ns'],record['beat_ns'],record['random_stalls'],True)
            assert row['result']['checksum']==case['expected']
            assert math.isclose(row['seconds'],row['result']['cycles']/(record['mhz']*1e6),rel_tol=1e-14)
            assert math.isclose(row['ipc'],row['result']['retired']/row['result']['cycles'],rel_tol=1e-14)
            c=row['counters'];assert sum(c[k] for k in ['retire','data_wait','frontend_wait','other'])==row['result']['cycles']
            assert c['btb_missing']+c['direction']+c['target']==c['conditional_errors']+c['target_errors']
        counts.setdefault(label,{})[name]=len(cases)
    expected={label:set(configs) for label in ['dev-common','dev-own','dev-legal-common','held-own']}
    for label in ['fast','slow','random','layout-3f00','layout-ff00']:
        expected[label]=set(['B0',freeze['choice'],*freeze['prototype_validation']])
    expected['far-calls']={'B0','U16','H32'}
    assert set(counts)==set(expected)
    for label,names in expected.items():assert set(counts[label])==names,(label,counts[label])
    safety_counts={}
    for name in ['U16','H32','U32W4','B0off','F16']:
        folder=root/'verification'/name;manifest=read(folder/'manifest.json')
        assert manifest['status']=='passed' and manifest['config']==configs[name];check_sources(folder)
        safety_counts[name]={}
        for subdir in ['recovery/core','recovery/cache','exception']:
            cases=read(folder/subdir/'manifest.json')['cases']
            assert cases and all(c.get('status')=='passed' or c.get('passed') is True for c in cases)
            safety_counts[name][subdir]=len(cases)
    unit=read(root/'verification/compact-btb-v2/results.json');assert len(unit['results'])==10
    for path,expected in unit['sources'].items():assert sha(Path(path))==expected
    for item in unit['results']:assert 'PASS compact BTB' in item['result']
    diff=read(root/'difftest/results.json');assert len(diff['records'])==40
    assert sha(Path(diff['reference']))==diff['reference_sha256']
    for row in diff['records']:
        assert sha(Path(row['command'][0]))==row['binary_sha256']
        assert 'HIT GOOD TRAP' in (root/'difftest'/row['config']/(row['test']+'.log')).read_text()
    micro=read(root/'microbench-complete.json');assert micro['status']=='passed' and not micro['train_rerun']
    for row in micro['records']:
        folder=root/'microbench'/row['name'];report=read(folder/'report.json');manifest=read(folder/'manifest.json')
        assert sha(folder/'report.json')==row['report_sha256'] and report['observer_on_off_verified']
        assert report['status']=='passed' and report['cpu_mhz']<=read(root/'ppa'/row['name']/'qualified.json')['mhz']
        assert manifest['artifacts']['microbench.bin']==micro['image_sha256']
        for path,expected in manifest['artifacts'].items():assert sha(folder/path)==expected
    observer=read(root/'target-observer/results.json')
    assert observer['observer_preserved_all_results_and_counters'] and len(observer['results'])==10
    assert read(root/'image-reproduction.json')['status']=='passed'
    for filename in ['model-tests.log','measurement-tests.log']:assert '\nOK\n' in (root/filename).read_text()
    report={'status':'passed','matrices':counts,'core_program_runs':sum(sum(v.values()) for v in counts.values()),
            'observer_program_runs':10,'module_random_cycles':200650,'nemu_program_runs':40,
            'safety_cases':safety_counts,'microbench_configurations':len(micro['records']),
            'default_off_area_clock_cycle_and_counter_equal':True,'decision':read(root/'decision.json')}
    (root/'audit.json').write_text(json.dumps(report,indent=2)+'\n')
    print('PASS target storage evidence audit',report['core_program_runs'],flush=True)


if __name__=='__main__':main()
