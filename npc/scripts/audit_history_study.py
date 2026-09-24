#!/usr/bin/env python3
"""Verify source bindings and completed history-study evidence; report pending work."""
import argparse
import json
from pathlib import Path
from explore_frontend import sha
from finish_history_study import NAMES
from audit_history_comparison import audit_comparison
from buffer_history_training import PARENTS,TOP


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--root',type=Path,required=True)
    p.add_argument('--partial',action='store_true')
    root=p.parse_args(); partial=root.partial;root=root.root.resolve()
    baseline=json.loads((root/'manifest.json').read_text())
    for path,value in baseline['sources'].items():assert sha(root/'baseline'/path)==value,path
    for path,value in json.loads((root/'candidate-hashes.json').read_text()).items():
        assert sha(root/'candidate-source'/path)==value,path
    cases=json.loads((root/'images/manifest.json').read_text())['cases'];assert len(cases)==22
    for case in cases:
        folder=root/'images'/case['name']
        for name,value in case['hashes'].items():assert sha(folder/name)==value
        data=(folder/'image.bin').read_bytes()
        assert (folder/'image.hex').read_text()==''.join(f'{int.from_bytes(data[i:i+4],"little"):08x}\n' for i in range(0,len(data),4))
    needed=['comparison.json','selection-freeze.json','timing-audit.json','infrastructure-parity.json',
            'history-model.json','model.json','model-parity.json','training-buffer-noop.json',
            'difftest/results.json','verification/T16/manifest.json','verification/T32/manifest.json',
            'microbench/B0I/report.json','microbench/T16/report.json']
    needed += [f'ppa/{n}/qualified.json' for n in NAMES]
    pending=[x for x in needed if not (root/x).exists()]
    for name in ['history-model.json','model.json']:
        if (root/name).exists() and len(json.loads((root/name).read_text())['cases'])!=10:
            pending.append(name+': incomplete cases')
    for n in NAMES:
        path=root/f'rtl/dev-common/{n}/results.json'
        if not path.exists():pending.append(str(path.relative_to(root)));continue
        data=json.loads(path.read_text());assert len(data['results'])==10
        assert sha(Path(data['results'][0]['command'][0]))==data['binary_sha256']
        for row in data['results']:
            assert row['result']['checksum']==row['case']['expected']
            assert sum(row['counters'][k] for k in ['retire','data_wait','frontend_wait','other'])==row['result']['cycles']
    for n in NAMES:
        ppa=root/'ppa'/n/'qualified.json'
        if not ppa.exists():continue
        qualified=json.loads(ppa.read_text());timing=json.loads((ppa.parent/'timing.json').read_text())
        mhz=qualified['mhz'];record=timing[str(mhz)]
        assert qualified['all_groups_passed'] and record['passed'] and record['violations']==0
        assert len(record['groups'])==4 and all(x['slack_ns']>=0 for x in record['groups'].values())
        if mhz<800:assert not timing[str(mhz+20)]['passed']
    if not pending:
        for name,parent in PARENTS.items():
            folder=root/'ppa'/name
            proof=json.loads((folder/'buffer-repair.json').read_text())
            assert proof['structural_equivalence']=='passed' and proof['added_registers']==0
            assert proof['maximum_fanout']<=16 and proof['threshold_loads']==64
            mapped=folder/f'sta/{TOP}-820MHz-buffered'
            original=root/'ppa'/parent/f'sta/{TOP}-820MHz-buffered'
            assert sha(mapped/(TOP+'.netlist.v'))==proof['netlist_sha256']
            assert sha(original/(TOP+'.netlist.v'))==proof['parent_netlist_sha256']
            assert sha(original/'buffered.json')==proof['parent_json_sha256']
            assert sha(mapped/'buffered.json')==proof['repaired_json_sha256']
            before=json.loads((original.parent.parent/'cells.json').read_text())
            after=json.loads((folder/'cells.json').read_text())
            expected=dict(before['cells']);expected['BUF_X4']+=proof['buffer_count']
            assert after['cells']==expected
            assert all(before[k]==after[k] for k in ['dff','data_latches','clock_gates'])
        noop=json.loads((root/'training-buffer-noop.json').read_text())
        assert set(noop)=={'B0I','T16','T32'} and all(x['inserted_buffers']==0 for x in noop.values())
        from verify_branch import check_sources
        difftest=json.loads((root/'difftest/results.json').read_text())
        assert sha(Path(difftest['reference']))==difftest['reference_sha256']
        for name,value in difftest['images'].items():
            assert sha(root/'difftest/images'/name)==value
        for name in ['T16','T32']:
            safety=json.loads((root/f'verification/{name}/manifest.json').read_text())
            assert safety['status']=='passed' and len(safety['tests'])==4
            check_sources(root/'verification'/name)
            entries=[x for x in difftest['records'] if x['config']==name]
            assert len(entries)==10 and len({x['test'] for x in entries})==10
            for row in entries:
                assert sha(Path(row['command'][0]))==row['binary_sha256']
                assert 'HIT GOOD TRAP' in (root/'difftest'/name/(row['test']+'.log')).read_text()
        tage=[]
        for folder in ['tage-tests','tage-tests-v2','tage-n32-p3']:
            path=root/folder/'results.json'
            if path.exists():tage+=json.loads(path.read_text())['results']
        assert {(x['entries'],x['policy']) for x in tage}=={(8,3),(16,3),(16,4),(32,3),(32,4)}
        assert all('PASS TAGE' in x['result'] for x in tage)
        audit_comparison(root)
        for name in ['B0I', 'T16']:
            report=json.loads((root/f'microbench/{name}/report.json').read_text())
            assert report['status']=='passed' and report['scale']=='test'
            assert report['observer_on_off_verified']
            assert report['cpu_mhz']<=json.loads((root/f'ppa/{name}/qualified.json').read_text())['mhz']
            for label in ['total','scored']:
                window=report[label]
                assert window['timer_seconds']==window['timer_ticks']/report['timer_hz']
                assert window['ipc']==window['retired_instructions']/window['cycles']
                assert window['cycle_seconds']==window['cycles']/(report['cpu_mhz']*1e6)
        old=json.loads((root/'microbench/B0I/report.json').read_text())
        new=json.loads((root/'microbench/T16/report.json').read_text())
        assert old['cpu_mhz']==new['cpu_mhz']
        assert all(old[k]['retired_instructions']==new[k]['retired_instructions'] for k in ['total','scored'])
    audit={'status':'pending' if pending else 'passed','pending':pending,
           'validated':'frozen baseline/candidate, 22 image hashes/HEX, completed nominal RTL binaries/checksums/cycle conservation, measured PPA pass and neighbour'}
    (root/'audit.json').write_text(json.dumps(audit,indent=2)+'\n')
    print(json.dumps(audit,indent=2))
    if pending and not partial:raise SystemExit(1)

if __name__=='__main__':main()
