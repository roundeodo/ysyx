#!/usr/bin/env python3
"""Evaluate the frozen roles, preserving failed/negative outcomes without retuning."""
import hashlib
import json

from summarize_btb import NPC, ROOT, paired


def main():
    docs = NPC/'docs/research/branch-v3'
    freeze = json.loads((docs/'selection-freeze.json').read_text())
    execution = json.loads((ROOT/'final-execution.json').read_text())
    assert execution['status'] == 'completed without retuning'
    assert execution['freeze_sha256'] == hashlib.sha256((docs/'selection-freeze.json').read_bytes()).hexdigest()
    assert freeze['development_report_sha256'] == hashlib.sha256((docs/'btb-results.json').read_bytes()).hexdigest()
    baseline = freeze['reference']
    base_mhz = freeze['reference_mhz']
    base_area = freeze['candidates'][baseline]['area_um2']
    results = []
    for name, candidate in freeze['candidates'].items():
        mhz = candidate['operating_mhz']
        suffix = lambda clock: [f'final-{clock}MHz-images-final', f'final-{clock}MHz-streams-final']
        short = paired(name, suffix(mhz), baseline, suffix(base_mhz))
        common = paired(name, suffix(400), baseline, suffix(400))
        large = paired(name, [f'final-{mhz}MHz-streams-long-paired-final'],
                       baseline, [f'final-{base_mhz}MHz-streams-long-paired-final'])
        assert short and common and large
        area_ratio = candidate['area_um2']/base_area
        results.append({'name': name, 'ppa': candidate['ppa'], 'mhz': mhz,
                        'area_um2': candidate['area_um2'], 'area_ratio': area_ratio,
                        'short_own': short, 'short_common_400': common, 'long_own': large,
                        'short_area_time_ratio': area_ratio*short['paired_geomean'],
                        'long_area_time_ratio': area_ratio*large['paired_geomean'],
                        'individual_regression_pass': max(short['worst_ratio'], large['worst_ratio']) <= 1.03})
    by_ppa = {row['ppa']: row for row in results}
    proposal = by_ppa[freeze['roles']['best_area_time']]
    accepted = (proposal['individual_regression_pass'] and proposal['short_area_time_ratio'] < 1
                and proposal['long_area_time_ratio'] <= 1)
    verdict = {'schema': 1, 'freeze_sha256': execution['freeze_sha256'],
               'roles_fixed_before_final': freeze['roles'], 'results': results,
               'proposal': proposal['ppa'], 'proposal_has_consistent_area_time_benefit': accepted,
               'default_changed': False,
               'decision': ('Measured balanced proposal has consistent benefit; retain stable profile and offer explicit experimental switches.'
                            if accepted else 'Keep stable default. The frozen proposal did not show consistent benefit on both final panels; do not choose a replacement using final data.'),
               'scope': 'fixed RV32I single-issue core, these frozen software inputs and memory services; no universal predictor ranking or post-route signoff'}
    (docs/'final-results.json').write_text(json.dumps(verdict, indent=2)+'\n')
    for row in results:
        print(row['ppa'], row['mhz'], row['area_um2'],
              'short', row['short_own']['paired_geomean'],
              'long', row['long_own']['paired_geomean'],
              'AT', row['short_area_time_ratio'], row['long_area_time_ratio'],
              'regression', row['individual_regression_pass'])
    print(verdict['decision'])


if __name__ == '__main__':
    main()
