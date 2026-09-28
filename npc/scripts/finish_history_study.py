#!/usr/bin/env python3
"""Complete timing-qualified comparisons, freeze selection, then evaluate held inputs."""
import argparse
import fcntl
from concurrent.futures import ThreadPoolExecutor
import json
import math
from pathlib import Path
import subprocess
import sys
import time
import explore_frontend as experiment
from buffer_history_training import PARENTS

NAMES=['B0','B0I','B512','G256','G512','T16','T32',*PARENTS]
SIMPLE_NAMES=['B512','G256','G512',*PARENTS]


def geometric(values):
    return math.exp(sum(map(math.log,values))/len(values))


def compare(candidate,baseline,area_ratio=1.0):
    references={x['case']['name']:x for x in baseline['results']}
    families={}; rows=[]
    for row in candidate['results']:
        ref=references[row['case']['name']]
        for key in ('retired','all_retired','digest','checksum'):
            assert row['result'][key]==ref['result'][key],(row['case']['name'],key)
        ratio=row['seconds']/ref['seconds']
        families.setdefault(row['case']['kind'],[]).append(ratio)
        rows.append({'case':row['case']['name'],'time_ratio':ratio,
                     'cycle_ratio':row['result']['cycles']/ref['result']['cycles'],
                     'i_beats_ratio':row['counters']['i_beats']/ref['counters']['i_beats']})
    value=geometric([geometric(x) for x in families.values()])
    return {'time_ratio_gm':value,'area_time_ratio_gm':value*area_ratio,
            'area_ratio':area_ratio,'worst_time_ratio':max(x['time_ratio'] for x in rows),'cases':rows}


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root',type=Path,required=True)
    p.add_argument('--wait-ppa',action='store_true',help='Wait for separately running PPA jobs instead of launching duplicates')
    p.add_argument('--qualified-only',choices=NAMES,help='Precompute one already qualified development configuration')
    a=p.parse_args(); root=a.root.resolve(); script=Path(__file__).with_name('explore_history.py')
    cases=json.loads((root/'images/manifest.json').read_text())['cases']
    def execute(command,label):
        with (root/(label+'.log')).open('w') as log:
            subprocess.run(list(map(str,command)),stdout=log,stderr=subprocess.STDOUT,check=True)
    def run_simulation(name,label,mhz,held=False,latency=100,random=False):
        out=root/'rtl'/label/name; path=out/'results.json'
        expected=sum(x['held']==held for x in cases)
        if path.exists():
            data=json.loads(path.read_text())
            assert data['mhz']==mhz and data['latency_ns']==latency and data['random_stalls']==random
            if len(data['results'])==expected:return data
        if out.exists():
            # Keep interrupted evidence; rebuilding a whole result is unambiguous.
            out.rename(out.with_name(name+'-incomplete-'+str(time.time_ns())))
        if name in PARENTS:
            parent=root/'rtl'/label/PARENTS[name]
            prior=parent/'results.json'
            if prior.exists():
                data=json.loads(prior.read_text())
                if (data['mhz']==mhz and data['latency_ns']==latency and
                    data['random_stalls']==random and len(data['results'])==expected):
                    import shutil
                    shutil.copytree(parent,out)
                    (out/'reuse.json').write_text(json.dumps({'parent':PARENTS[name],
                        'reason':'Identical RTL/binary/parameters; mapped buffers add no logical cycles.'},indent=2)+'\n')
                    return data
        command=[sys.executable,script,'run','--root',root,'--config',name,'--label',label,
                 '--mhz',str(mhz),'--latency-ns',str(latency)]
        if held:command.append('--held')
        if random:command.append('--random-stalls')
        execute(command,label+'-'+name)
        data=json.loads(path.read_text());assert len(data['results'])==expected
        print('PASS',label,name,mhz,flush=True);return data
    def simulation(name,label,mhz,held=False,latency=100,random=False):
        locks=root/'locks';locks.mkdir(exist_ok=True)
        with (locks/(label+'-'+name+'.lock')).open('a') as lock:
            fcntl.flock(lock,fcntl.LOCK_EX)
            return run_simulation(name,label,mhz,held,latency,random)
    if a.qualified_only:
        path=root/'ppa'/a.qualified_only/'qualified.json'
        while not path.exists():time.sleep(10)
        qualified=json.loads(path.read_text());assert qualified['all_groups_passed']
        mhz=qualified['mhz']
        simulation(a.qualified_only,'dev-common' if mhz==720 else f'dev-own-{mhz}',mhz)
        return
    ppa={}
    for name in NAMES:
        path=root/'ppa'/name/'qualified.json'
        while not path.exists():
            if a.wait_ppa:time.sleep(10)
            else:
                command=[sys.executable,script,'ppa','--root',root,'--config',name]
                if (root/'ppa'/name).exists():command.append('--resume')
                execute(command,'ppa-finish-'+name)
        ppa[name]=json.loads(path.read_text());assert ppa[name]['all_groups_passed']
    common_mhz=min(x['mhz'] for x in ppa.values()); common={}; own={}
    def development(name):
        label='dev-common' if common_mhz==720 else f'dev-common-{common_mhz}'
        shared=simulation(name,label,common_mhz)
        mhz=ppa[name]['mhz']
        qualified=shared if mhz==common_mhz else simulation(name,'dev-common' if mhz==720 else f'dev-own-{mhz}',mhz)
        return name,shared,qualified
    # Each worker owns a distinct output directory and simulator process. Limit
    # concurrency to four: simulators are small; synthesis remains separately limited.
    with ThreadPoolExecutor(max_workers=4) as workers:
        for name,shared,qualified in workers.map(development,NAMES):
            common[name]=shared;own[name]=qualified
    scores={name:compare(own[name],own['B0'],ppa[name]['area_um2']/ppa['B0']['area_um2']) for name in NAMES}
    eligible=[n for n in NAMES if n!='B0I' and scores[n]['worst_time_ratio']<=1.03]
    selected=min(eligible,key=lambda n:scores[n]['area_time_ratio_gm'])
    simple=min(SIMPLE_NAMES,key=lambda n:scores[n]['area_time_ratio_gm'])
    tage=min(['T16','T32'],key=lambda n:scores[n]['area_time_ratio_gm'])
    freeze={'criterion':'equal-family geometric area*time, <=3% individual time regression; held data never tune parameters',
            'common_mhz':common_mhz,'ppa':ppa,'development':scores,
            'selected_development':selected,'simple_comparator':simple,'tage_comparator':tage,
            'held_configurations':list(dict.fromkeys(['B0','B0I',simple,tage,selected])),
            'configuration_sha256':experiment.sha(root/'configurations.json'),
            'images_manifest_sha256':experiment.sha(root/'images/manifest.json')}
    path=root/'selection-freeze.json'
    if path.exists():assert json.loads(path.read_text())==freeze
    else:path.write_text(json.dumps(freeze,indent=2)+'\n')
    print('SELECTION FROZEN',selected,'simple',simple,'TAGE',tage,flush=True)
    held_own={};held_common={}
    def held(name):
        shared=simulation(name,f'held-common-{common_mhz}',common_mhz,held=True)
        mhz=ppa[name]['mhz']
        qualified=shared if mhz==common_mhz else simulation(name,f'held-own-{mhz}',mhz,held=True)
        return name,shared,qualified
    with ThreadPoolExecutor(max_workers=4) as workers:
        for name,shared,qualified in workers.map(held,freeze['held_configurations']):
            held_common[name]=shared;held_own[name]=qualified
    held_scores={n:compare(x,held_own['B0'],ppa[n]['area_um2']/ppa['B0']['area_um2']) for n,x in held_own.items()}
    accepted=selected if (held_scores[selected]['area_time_ratio_gm']<1 and held_scores[selected]['worst_time_ratio']<=1.03) else 'B0'
    sensitivity={}
    sensitivity_runs={}
    jobs=[]
    for latency,stalls in [(20,False),(200,False),(100,True)]:
        label=f'sensitivity-{latency}-stalls{int(stalls)}-{common_mhz}'
        for name in list(dict.fromkeys(['B0',simple,tage])):
            jobs.append((label,name,latency,stalls))
    def sensitivity_run(job):
        label,name,latency,stalls=job
        data=simulation(name,label,common_mhz,latency=latency,random=stalls)
        return label,name,data
    with ThreadPoolExecutor(max_workers=4) as workers:
        for label,name,data in workers.map(sensitivity_run,jobs):
            sensitivity_runs.setdefault(label,{})[name]=data
    for label,runs in sensitivity_runs.items():
        sensitivity[label]={name:compare(data,runs['B0'],ppa[name]['area_um2']/ppa['B0']['area_um2'])
                            for name,data in runs.items() if name!='B0'}
    report={'status':'performance and PPA comparisons complete; correctness results indexed separately',
            'freeze':freeze,'common_development':{n:compare(x,common['B0']) for n,x in common.items()},
            'held_own_frequency':held_scores,'held_common_frequency':{n:compare(x,held_common['B0']) for n,x in held_common.items()},
            'sensitivity':sensitivity,'recommendation':accepted,'stable_default_changed':False}
    (root/'comparison.json').write_text(json.dumps(report,indent=2)+'\n')
    print('PASS comparisons; recommendation',accepted,flush=True)

if __name__=='__main__':main()
