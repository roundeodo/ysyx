#!/usr/bin/env python3
"""Select once on development data; held results never enter this ranking."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path

from explore_frontend import sha
from select_icache import CONFIGS, MODERN_POLICIES
from summarize_icache_selection import compare


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--freeze', action='store_true')
    args = parser.parse_args()
    root = args.root.resolve()
    baseline = root / 'rtl/dev-own/B0/results.json'
    base_area = json.loads((root / 'ppa/B0/qualified.json').read_text())['area_um2']
    rows, missing, inputs = [], [], {}
    for name, config in CONFIGS.items():
        performance = root / 'rtl/dev-own' / name / 'results.json'
        qualification = root / 'ppa' / name / 'qualified.json'
        same_clock = root / 'rtl/dev-580' / name / 'results.json'
        paths = [performance, qualification, same_clock]
        if not all(p.exists() for p in paths) or any(
                len(json.loads(p.read_text())['results']) != 6 for p in [performance, same_clock]):
            missing.append(name)
            continue
        ppa = json.loads(qualification.read_text())
        assert ppa['all_groups_passed'], name
        own = compare(baseline, performance)
        same = compare(root / 'rtl/dev-580/B0/results.json', same_clock)
        assert own['mhz'] == ppa['mhz'], name
        for p in paths:
            inputs[str(p.relative_to(root))] = sha(p)
        row = {'name': name, 'config': config, 'area_um2': ppa['area_um2'], 'mhz': ppa['mhz'],
               'dev_own': own, 'same_580': same, 'same_580_timing_passed': ppa['mhz'] >= 580,
               'area_ratio': ppa['area_um2'] / base_area,
               'area_time_ratio': ppa['area_um2'] / base_area * own['time_ratio_gm']}
        rows.append(row)
    rows.sort(key=lambda row: row['area_time_ratio'])
    for row in rows:
        print(f'{row["name"]:14s} {row["area_um2"]:11.3f} {row["mhz"]:3d} MHz '
              f'time={row["dev_own"]["time_ratio_gm"]:.5f} '
              f'area*time={row["area_time_ratio"]:.5f}')
    result = {'rows': rows, 'missing': missing, 'selection_dataset': 'dev only', 'inputs': inputs}
    (root / 'development-ranking.json').write_text(json.dumps(result, indent=2) + '\n')
    if args.freeze:
        assert not missing, f'Incomplete experiments: {missing}'
        assert rows and all(not x['case']['held'] for x in json.loads(baseline.read_text())['results'])
        selected = rows[0]
        simple = [row for row in rows if row['config'][2] not in MODERN_POLICIES]
        matched = [row for row in simple if row['config'][:2] == selected['config'][:2]
                   and row['config'][3] == selected['config'][3]]
        result.update(frozen_at=datetime.now(timezone.utc).isoformat(), selected=selected['name'],
                      best_simple=simple[0]['name'],
                      matched_simple=matched[0]['name'] if matched else None,
                      fastest=min(rows, key=lambda x: x['dev_own']['seconds_gm'])['name'],
                      smallest=min(rows, key=lambda x: x['area_um2'])['name'],
                      held_policy='Validate frozen winner; every held case <=1.03 B0 own-frequency time. '
                                  'A modern policy must also retain its area*time advantage over frozen '
                                  'best_simple on held data, with no held case >1.03 best_simple. '
                                  'Otherwise keep frozen best_simple if it meets the B0 limit; else B0. '
                                  'No parameter retuning after held feedback.')
        with (root / 'selection-freeze.json').open('x') as stream:
            json.dump(result, stream, indent=2)
            stream.write('\n')
        print('FROZEN', result['selected'], 'fastest', result['fastest'], 'smallest', result['smallest'])
    else:
        print('PENDING', ', '.join(missing))


if __name__ == '__main__':
    main()
