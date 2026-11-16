#!/usr/bin/env python3
"""Freeze roles from completed validation; no final inputs or outcomes are consulted."""
import datetime
import hashlib
import json
import subprocess
from pathlib import Path

from run_large_btb_matrix import POINTS
from summarize_btb import NPC, ROOT

DOCS = NPC/'docs/research/branch-v3'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    output = DOCS/'selection-freeze.json'
    assert not output.exists(), 'Selection was already frozen; do not retune'
    assert not any((ROOT/name).exists() for name in
                   ['images-final', 'streams-final', 'streams-long-paired-final'])
    measured = json.loads((DOCS/'btb-results.json').read_text())
    assert not any(measured['pending'].values())
    assert len(measured['results']) == 35
    assert all(row['common_legal_400'] for row in measured['results'])
    assert len(measured['sensitivity']) == 36
    validation = {row['name']: row for row in measured['validation']}
    assert len(validation) == 10
    large = {(row['split'], row['name']): row for row in measured['long_legal']}
    assert len(large) == 2*len(POINTS), 'Finish both long development and validation first'
    for name in ['BT32-select-fold', 'NSL-BT32-fold', 'NSL-BT64', 'H2E-victim']:
        records = json.loads((ROOT/'safety'/name/'results.json').read_text())
        assert len(records) == 4 and all(row['returncode'] == 0 for row in records)
    assert 'PASS BTB' in (ROOT/'btb-unit-expanded/run.log').read_text()
    assert all(r['detected'] for r in json.loads((ROOT/'btb-mutations/results.json').read_text()))
    assert json.loads((ROOT/'btb-mutations-valid/results.json').read_text())[0]['detected']
    for run in ['NSL-BT32-fold-events-proxy', 'NSL-BT32-fold-events-real']:
        assert all(row['status'] == 'passed' for row in
                   json.loads((ROOT/'rtl'/run/'model-check.json').read_text()))

    # Short proxy/real application families remain the declared primary score;
    # long requests are a separately reported generalization/regression check.
    # A final result can reject a role, never retune it or select a new winner.
    choices = {}
    rejected = {}
    for binary, (ppa, mhz) in POINTS.items():
        short, long = validation[ppa], large['validation', binary]
        if max(short['worst_ratio'], long['worst_ratio']) > 1.03:
            rejected[ppa] = {'short_worst': short['worst_ratio'], 'long_worst': long['worst_ratio']}
            continue
        choices[ppa] = {'binary': binary, 'mhz': mhz, 'area': short['area_um2'],
                        'time': short['paired_geomean'], 'area_time': short['area_time_ratio']}
    assert 'BT0' in choices
    least_cost = min(choices, key=lambda n: choices[n]['area'])
    balanced = min(choices, key=lambda n: choices[n]['area_time'])
    fastest = min(choices, key=lambda n: choices[n]['time'])
    budgets = {}
    for percent in [0, 5, 10, 20]:
        permitted = [n for n in choices if choices[n]['area'] <= choices['BT0']['area']*(1+percent/100)]
        budgets[str(percent)] = min(permitted, key=lambda n: choices[n]['time'])
    pareto = [name for name, row in choices.items() if not any(
        other != name and candidate['area'] <= row['area'] and candidate['time'] <= row['time']
        and (candidate['area'] < row['area'] or candidate['time'] < row['time'])
        for other, candidate in choices.items())]
    candidates = {}
    for ppa in sorted(set(pareto) | {'BT0', balanced, least_cost, fastest, *budgets.values()}):
        row = choices[ppa];binary = row['binary'];mhz = row['mhz']
        candidates[binary] = {'ppa': ppa, 'operating_mhz': mhz, 'mhz': sorted({400, mhz}),
                             'area_um2': row['area'],
                             'binary_sha256': sha(ROOT/'builds'/binary/'obj/Vexploration_core_tb'),
                             'build_manifest_sha256': sha(ROOT/'builds'/binary/'manifest.json')}
    record = {'schema': 2, 'frozen_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'git_head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=NPC.parent, text=True).strip(),
              'development_report_sha256': sha(DOCS/'btb-results.json'), 'candidates': candidates,
              'reference': 'BT0-long', 'reference_mhz': 735, 'common_mhz': 400,
              'primary_metric': 'equal application families, equal inputs within family, paired time geomean',
              'selection_basis': 'eight-family short validation score, plus <=3% individual regression on short and 128-request validation',
              'final_proxy_seeds': [2467, 2474], 'final_vocabulary_key_ranges': [[512, 768], [33792, 42496]],
              'final_protocol': 'short proxy and real streams at common/own clocks; 128-request streams at own clocks; report short and long separately',
              'roles': {'lowest_cost': least_cost, 'best_area_time': balanced,
                        'lowest_latency_by_area_percent': budgets, 'unconstrained_lowest_latency': fastest},
              'pareto_validation': pareto, 'validation_rejected': rejected,
              'acceptance': 'No final per-input slowdown >3%; the frozen balanced proposal must beat stable baseline and stronger simple controls in area*time, with long-input consistency. Incomplete coverage or a failed role keeps the stable default.',
              'no_retuning': 'Final results may veto roles, never choose new parameters, weights, frequencies or workloads'}
    output.write_text(json.dumps(record, indent=2)+'\n')
    print('FROZEN', output, record['roles'])


if __name__ == '__main__':
    main()
