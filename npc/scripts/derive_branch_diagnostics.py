#!/usr/bin/env python3
"""Check default equivalence, image reproduction and the fixed I-cache crossing."""
import argparse
import json
import math
from pathlib import Path
from explore_frontend import sha


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root', type=Path, required=True)
    a = p.parse_args()
    root = a.root.resolve()
    def rows(label, config):
        data = json.loads((root / 'rtl' / label / config / 'results.json').read_text())['results']
        return {row['case']['name']: row for row in data}
    for label in ['dev-common', 'dev-own']:
        before, after = rows(label, 'B0'), rows(label, 'B0current')
        assert len(before) == len(after) == 10 and before.keys() == after.keys()
        for name in before:
            assert before[name]['result'] == after[name]['result']
            assert before[name]['counters'] == after[name]['counters']
    cells = {name: json.loads((root / 'ppa' / name / 'cells.json').read_text())
             for name in ['B0', 'B0current']}
    for key in ['dff', 'data_latches', 'clock_gates']:
        assert cells['B0'][key] == cells['B0current'][key]
    frequencies = {name: json.loads((root / 'ppa' / name / 'qualified.json').read_text())['mhz']
                   for name in ['B0', 'B0current']}
    assert frequencies['B0'] == frequencies['B0current']
    (root / 'default-integration.json').write_text(json.dumps({
        'common_mhz': 660, 'own_mhz': frequencies['B0'], 'cases_each': 10,
        'all_results_and_counters_identical': True,
        'area_change_um2': cells['B0current']['area_um2'] - cells['B0']['area_um2'],
        'same_dff': cells['B0']['dff'], 'same_data_latches': cells['B0']['data_latches'],
        'same_clock_gates': cells['B0']['clock_gates']}, indent=2) + '\n')
    crossing = {name: rows('dev-common', name) for name in ['B0', 'O0', 'G128', 'OG128', 'M64', 'OM64']}
    ratios = {}
    families = sorted({row['case']['kind'] for row in crossing['B0'].values()})
    for family in families:
        names = [name for name, row in crossing['B0'].items() if row['case']['kind'] == family]
        ratios[family] = {}
        for label, measured, reference in [('icache_new_over_old', 'B0', 'O0'),
                ('G128_new', 'G128', 'B0'), ('G128_old', 'OG128', 'O0'),
                ('M64_new', 'M64', 'B0'), ('M64_old', 'OM64', 'O0')]:
            values = []
            for name in names:
                for field in ['retired', 'all_retired', 'digest', 'checksum']:
                    assert crossing[measured][name]['result'][field] == crossing[reference][name]['result'][field]
                values.append(crossing[measured][name]['result']['cycles'] /
                              crossing[reference][name]['result']['cycles'])
            ratios[family][label] = math.exp(sum(map(math.log, values)) / len(values))
    (root / 'cache-interaction.json').write_text(json.dumps({
        'scope': 'functional 660 MHz memory-model diagnostic only; old caches unqualified and G128 fails STA at 660 MHz; not used for hardware selection',
        'ratios': ratios}, indent=2) + '\n')
    original = json.loads((root / 'images/manifest.json').read_text())
    rebuilt = json.loads((root / 'images-reproduction/manifest.json').read_text())
    assert [x['name'] for x in original['cases']] == [x['name'] for x in rebuilt['cases']]
    records = []
    for old, new in zip(original['cases'], rebuilt['cases']):
        assert all(old[key] == new[key] for key in ['name', 'expected', 'seed', 'held', 'kind', 'begin_pc', 'end_pc'])
        for filename in ['image.bin', 'image.hex']:
            before = root / 'images' / old['name'] / filename
            after = root / 'images-reproduction' / old['name'] / filename
            assert before.read_bytes() == after.read_bytes()
            records.append({'case': old['name'], 'artifact': filename, 'sha256': sha(after)})
    (root / 'image-reproduction.json').write_text(json.dumps({
        'status': 'passed', 'cases': 22, 'comparison': records,
        'new_manifest_sha256': sha(root / 'images-reproduction/manifest.json')}, indent=2) + '\n')
    print('PASS diagnostics, default equivalence and exact software image reproduction')


if __name__ == '__main__':
    main()
