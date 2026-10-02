#!/usr/bin/env python3
"""Collect source-bound timing experiments and paired software measurements."""
import hashlib
import json
from pathlib import Path

from summarize import identity, means, read_records

NPC = Path(__file__).resolve().parents[2]
ROOT = NPC/'result/branch-v3'


def evidence(path):
    return {'path': str(path.relative_to(NPC)),
            'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}


def compare(records, candidates, references):
    selected = [row for row in records if row['run'] in candidates]
    baseline = {identity(row): row for row in records if row['run'] in references}
    assert len(selected) == 14 and len(baseline) == 14
    details = []
    for row in selected:
        other = baseline[identity(row)]
        assert row['retired'] == other['retired']
        details.append({'case': row['case'], 'family': row['family'],
                        'candidate_run': row['run'], 'reference_run': other['run'],
                        'candidate_cycles': row['cycles'], 'reference_cycles': other['cycles'],
                        'candidate_mhz': row['mhz'], 'reference_mhz': other['mhz'],
                        'time_ratio': row['seconds']/other['seconds']})
    return {**means(details), 'details': details}


def main():
    output = {'scope': '700MHz circuit optimization; final holdout and selection remain unfinished',
              'process': 'NanGate45, AREA 3, 820MHz mapping, unchanged reset/IO constraints',
              'points': {}, 'native_test': {}, 'comparisons': {}, 'evidence': []}
    for name in ('B0off', 'B0-victim', 'NSL', 'NSL-parallel', 'NSL-provider', 'NSL-victim'):
        point = ROOT/'ppa'/name
        qualified = point/'qualified.json'
        assert qualified.exists(), f'Qualification unfinished: {name}'
        values = {'coarse': json.loads(qualified.read_text()),
                  'source_hashes': json.loads((point/'source-hashes.json').read_text()),
                  'command': json.loads((point/'command.json').read_text())}
        for filename in ('qualified-fine.json', 'timing.json', 'timing-fine.json', 'probe-700.json'):
            if (point/filename).exists():
                values[filename.removesuffix('.json')] = json.loads((point/filename).read_text())
        output['points'][name] = values
        output['evidence'].append(evidence(qualified))
    for name in ('native-B0-victim-720', 'native-NSL-victim-700'):
        report = ROOT/name/'report.json'
        output['native_test'][name] = json.loads(report.read_text())
        assert output['native_test'][name]['observer_on_off_verified']
        output['evidence'].append(evidence(report))
    records = read_records()
    candidate = {'NSL-victim-dev', 'NSL-victim-stream-dev-700'}
    for label, reference in {
        'same_700MHz_against_B0': {'B0-victim-dev', 'B0-victim-stream-dev-700'},
        '700MHz_against_B0_720MHz': {'B0-victim-dev-720', 'B0-victim-stream-dev-720'},
        '700MHz_against_original_NSL_540MHz': {'NSL-540MHz-proxy', 'NSL-540MHz-stream'},
    }.items():
        output['comparisons'][label] = compare(records, candidate, reference)
    for relative in ('sc-parallel-cycle-equivalence.json', 'provider-parallel-cycle-equivalence.json',
                     'provider-parallel-stream-equivalence.json', 'victim-parallel-cycle-equivalence.json',
                     'victim-parallel-unit/manifest.json', 'safety/NSL-victim/results.json',
                     'safety/B0-victim/results.json', 'isa/difftest/results.json'):
        output['evidence'].append(evidence(ROOT/relative))
    destination = NPC/'docs/research/branch-v3/timing-700-results.json'
    destination.write_text(json.dumps(output, indent=2)+'\n')
    print(destination)
    for name, result in output['comparisons'].items():
        print(name, result['paired_geomean'], result['worst_ratio'])


if __name__ == '__main__':
    main()
