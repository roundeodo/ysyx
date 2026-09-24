#!/usr/bin/env python3
"""Qualify target-storage comparisons, freeze selection, then evaluate held inputs."""
import argparse
from datetime import datetime, timezone
import json
import math
from pathlib import Path
import subprocess
import time
from explore_frontend import sha
from qualify_branch_runs import check_architecture, check_command


def read(path):
    return json.loads(path.read_text())


def gm(values):
    return math.exp(sum(map(math.log, values)) / len(values))


def compare(reference, measured, area_ratio):
    check_architecture(reference, measured)
    base = {r['case']['name']: r for r in reference['results']}
    families, traffic, ratios = {}, {}, {}
    for row in measured['results']:
        other = base[row['case']['name']]
        ratio = row['seconds'] / other['seconds']
        ratios[row['case']['name']] = ratio
        families.setdefault(row['case']['kind'], []).append(ratio)
        traffic.setdefault(row['case']['kind'], []).append(row['counters']['i_beats'] / other['counters']['i_beats'])
    families = {kind: gm(values) for kind, values in families.items()}
    return {'time_ratio_gm': gm(list(families.values())), 'adp_ratio': gm(list(families.values())) * area_ratio,
            'families': families, 'input_time_ratios': ratios, 'max_input_time_ratio': max(ratios.values()),
            'i_beats_ratio_gm': gm([gm(values) for values in traffic.values()]),
            'i_beats_families': {kind: gm(values) for kind, values in traffic.items()}}


def measure(root, name, label, mhz, *, held=False, images=None, latency=100, beat=10, stalls=False):
    images = images or root / 'images'
    path = root / 'rtl' / label / name / 'results.json'
    if not path.exists():
        command = ['python3', 'npc/scripts/explore_target_storage.py', 'run', '--root', str(root),
                   '--config', name, '--label', label, '--mhz', str(mhz), '--images', str(images),
                   '--latency-ns', str(latency), '--beat-ns', str(beat)]
        if held: command.append('--held')
        if stalls: command.append('--random-stalls')
        subprocess.run(command, check=True)
    data = read(path)
    for key, expected in [('mhz', mhz), ('latency_ns', latency), ('beat_ns', beat), ('random_stalls', stalls), ('memory_mode', 'physical')]:
        assert data[key] == expected
    binary = root / 'builds' / name / 'obj/Vexploration_core_tb'
    assert data['binary_sha256'] == sha(binary)
    cases = {c['name']: c for c in read(images / 'manifest.json')['cases'] if c['held'] == held}
    assert len(data['results']) == len(cases)
    assert {r['case']['name'] for r in data['results']} == set(cases)
    for row in data['results']:
        case = cases[row['case']['name']]
        assert row['case'] == case and row['result']['checksum'] == case['expected']
        check_command(row['command'], binary, images / case['name'] / 'image.hex', case, mhz, latency, beat, stalls, True)
        assert math.isclose(row['seconds'], row['result']['cycles'] / (mhz * 1e6), rel_tol=1e-14)
        assert math.isclose(row['ipc'], row['result']['retired'] / row['result']['cycles'], rel_tol=1e-14)
    return data


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('action', choices=['development', 'held'])
    p.add_argument('--root', type=Path, required=True)
    a = p.parse_args(); root = a.root.resolve()
    names = list(read(root / 'configurations.json'))
    deadline = time.monotonic() + 3600
    while not all((root / 'ppa' / name / 'qualified.json').exists() for name in names):
        if time.monotonic() > deadline: raise RuntimeError('PPA incomplete')
        time.sleep(10)
    ppa = {n: read(root / 'ppa' / n / 'qualified.json') for n in names}
    common = min(v['mhz'] for v in ppa.values())
    if a.action == 'development':
        results = {}
        for name in names:
            results[name] = {'own': measure(root, name, 'dev-own', ppa[name]['mhz']),
                             'common': measure(root, name, 'dev-legal-common', common)}
        summary = {'common_mhz': common, 'configurations': {}}
        for name in names:
            ratio = ppa[name]['area_um2'] / ppa['B0']['area_um2']
            summary['configurations'][name] = {'ppa': ppa[name], **{
                label: compare(results['B0'][label], results[name][label], ratio) for label in ['own', 'common']}}
        (root / 'development-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
        eligible = [n for n in names if summary['configurations'][n]['own']['max_input_time_ratio'] <= 1.03]
        chosen = min(eligible, key=lambda n: summary['configurations'][n]['own']['adp_ratio'])
        freeze = {'utc': datetime.now(timezone.utc).isoformat(), 'choice': chosen,
                  'policy': 'minimum development whole-core area*time GM, equal family weights, 3% per-input guard; no retuning on held/layout',
                  'development_sha256': sha(root/'development-summary.json'), 'configurations_sha256': sha(root/'configurations.json'),
                  'held_seeds': [2053,4099], 'layout_offsets': ['3f00','ff00'],
                  'prototype_validation': ['U16','H32'],
                  'note': 'All frozen controls also reported on held inputs; held data cannot select another winner'}
        with (root/'selection-freeze.json').open('x') as f: f.write(json.dumps(freeze,indent=2)+'\n')
        print('FROZEN', chosen, common, flush=True)
    else:
        frozen = read(root / 'selection-freeze.json')
        assert frozen['development_sha256'] == sha(root / 'development-summary.json')
        chosen = frozen['choice']
        results = {n: measure(root, n, 'held-own', ppa[n]['mhz'], held=True) for n in names}
        summary = {n: compare(results['B0'], results[n], ppa[n]['area_um2']/ppa['B0']['area_um2']) for n in names}
        (root/'held-summary.json').write_text(json.dumps(summary,indent=2)+'\n')
        # Even a baseline development choice cannot hide compressed-target boundary failures.
        sensitivity_names = list(dict.fromkeys(['B0', chosen, *frozen['prototype_validation']]))
        sensitivity = {}
        for label, images, latency, beat, stalls in [
                ('layout-3f00',root/'layouts/3f00',100,10,False),
                ('layout-ff00',root/'layouts/ff00',100,10,False),
                ('fast',root/'images',50,5,False), ('slow',root/'images',200,20,False),
                ('random',root/'images',100,10,True)]:
            measured = {n: measure(root,n,label,ppa[n]['mhz'],images=images,latency=latency,beat=beat,stalls=stalls) for n in sensitivity_names}
            sensitivity[label] = {n: compare(measured['B0'],measured[n],ppa[n]['area_um2']/ppa['B0']['area_um2']) for n in sensitivity_names}
        (root/'sensitivity.json').write_text(json.dumps(sensitivity,indent=2)+'\n')
        accepted = summary[chosen]['adp_ratio'] <= 1 and summary[chosen]['max_input_time_ratio'] <= 1.03
        accepted &= all(sensitivity[label][chosen]['max_input_time_ratio'] <= 1.03 for label in ['layout-3f00','layout-ff00'])
        decision = {'development_choice': chosen, 'recommendation': chosen if accepted else 'B0',
                    'held_accepted': bool(accepted), 'default_enabled': False,
                    'note': 'Prototypes remain opt-in; no held-data retuning or replacement of frozen winner'}
        (root/'decision.json').write_text(json.dumps(decision,indent=2)+'\n')
        print('DECISION',decision,flush=True)


if __name__ == '__main__': main()
