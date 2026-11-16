#!/usr/bin/env python3
"""Apply the frozen acceptance rule and export measured, auditable comparisons."""
import argparse
import csv
import json
from pathlib import Path

from explore_frontend import sha
from select_icache import MODERN_POLICIES
from summarize_icache_selection import compare, geometric_mean


def read(path):
    return json.loads(path.read_text())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    freeze = read(root / 'selection-freeze.json')
    validation = read(root / 'validation-complete.json')
    assert validation['status'] == 'passed'
    for relative, digest in freeze['inputs'].items():
        assert sha(root / relative) == digest, f'Frozen input changed: {relative}'
    protocol = validation['protocol']
    rows = {row['name']: row for row in freeze['rows']}
    names = protocol['held_configs']
    common = f'dev-common-{protocol["common_mhz"]}'
    labels = ['dev-own', common, 'held-common', 'held-own'] + [
        f'held-sensitivity-{first}-{beat}-{int(stalls)}'
        for first, beat, stalls in protocol['sensitivity']]
    comparisons, hashes, cases = {}, {}, []
    for label in labels:
        comparisons[label] = {}
        selected_names = list(rows) if label.startswith('dev-') else names
        for name in selected_names:
            source = root / 'rtl' / label / name / 'results.json'
            measured = read(source)
            held = label.startswith('held-')
            assert all(case['case']['held'] == held for case in measured['results'])
            assert measured['mhz'] <= rows[name]['mhz'], (label, name)
            value = compare(root / 'rtl' / label / 'B0/results.json', source)
            value['area_time_ratio'] = rows[name]['area_ratio'] * value['time_ratio_gm']
            value['instruction_beats_ratio_gm'] = geometric_mean([
                case['instruction_beat_ratio'] for case in value['cases']])
            comparisons[label][name] = value
            hashes[str(source.relative_to(root))] = sha(source)
            for case in value['cases']:
                counter = case['counters']
                cases.append(dict(label=label, config=name, workload=case['name'],
                                  mhz=value['mhz'], cycles=case['cycles'], seconds=case['seconds'],
                                  ipc=case['ipc'], time_ratio=case['time_ratio'],
                                  lookups=counter['lookups'], misses=counter['misses'],
                                  instruction_beats=counter['i_beats'], data_transfer_cycles=counter['d_beats'],
                                  instruction_beat_ratio=case['instruction_beat_ratio'],
                                  frontend_wait=counter['frontend_wait'], data_wait=counter['data_wait'],
                                  frontend_wait_fraction=counter['frontend_wait'] / case['cycles'],
                                  data_wait_fraction=counter['data_wait'] / case['cycles']))

    # Explicit single-change and circuit-only controls. These do not select or
    # retune the winner; all inputs were declared before held execution.
    controls = [
        ('B0', 'line32', 'line bytes'),
        ('B0', 'capacity', 'capacity'),
        ('capacity', 'c512d32', 'line bytes'),
        ('line32', 'c256f32', 'associativity with FIFO'),
        ('c1f32', 'c1p32', 'FIFO to Tree-PLRU'),
        ('c1f32', 'c1legacy32', 'FIFO to original SRRIP'),
        ('c1legacy32', 'c1s32', 'SRRIP query and same-edge hit forwarding boundary'),
        ('c1s32', 'c1br32', 'bimodal insertion'),
        ('c1s32', 'c1b32', 'access-segment promotion'),
        ('c1sbypass32', 'c1bypass32', 'access-segment promotion with query bypass'),
        ('c1b32', 'c1h32', 'combined learning table and path history'),
        ('c1bypass32', 'c1hq32', 'combined learning table and history with query bypass'),
        ('c1b32', 'c1bypass32', 'query circuit only; same replacement events'),
        ('c1s32', 'c1sbypass32', 'query circuit only; same replacement events'),
        ('c1h32', 'c1hq32', 'query circuit only; same replacement events'),
        ('c2pc64', 'c2pcq64', 'query circuit only; same replacement events'),
        ('c1p16', 'c1p32', 'line bytes'),
        ('c1p32', 'c1p8', 'associativity with Tree-PLRU'),
        ('c1b32', 'c1b8', 'associativity with access-segment promotion'),
        ('c1p32', 'c2p32', 'capacity with Tree-PLRU'),
        ('c2p32', 'c2p64', 'line bytes'),
        ('c2p64', 'c2pc64', 'combined policy change; not isolated learning-table credit'),
    ]
    ablations = []
    for control, candidate, factor in controls:
        same = compare(root / 'rtl' / common / control / 'results.json',
                       root / 'rtl' / common / candidate / 'results.json')
        own = compare(root / 'rtl/dev-own' / control / 'results.json',
                      root / 'rtl/dev-own' / candidate / 'results.json')
        query_equivalent = None
        if factor.startswith('query circuit only'):
            left = read(root / 'rtl' / common / control / 'results.json')['results']
            right = read(root / 'rtl' / common / candidate / 'results.json')['results']
            query_equivalent = all(a['result'] == b['result'] and a['counters'] == b['counters']
                                   for a, b in zip(left, right))
            assert query_equivalent, (control, candidate, 'Query bypass changed event behavior')
        area_ratio = rows[candidate]['area_um2'] / rows[control]['area_um2']
        ablations.append({'control': control, 'candidate': candidate, 'factor': factor,
                          'area_ratio': area_ratio, 'common_clock': same, 'legal_frequency': own,
                          'query_event_equivalence': query_equivalent,
                          'area_time_ratio': area_ratio * own['time_ratio_gm']})
    (root / 'ablations.json').write_text(json.dumps(ablations, indent=2) + '\n')

    winner, simple = freeze['selected'], freeze['best_simple']
    held = comparisons['held-own']
    primary_ok = held[winner]['time_ratio_worst'] <= 1.03
    reasons = []
    if not primary_ok:
        reasons.append('Development winner violates the per-case held baseline bound')
    if rows[winner]['config'][2] in MODERN_POLICIES:
        against_simple = compare(root / 'rtl/held-own' / simple / 'results.json',
                                 root / 'rtl/held-own' / winner / 'results.json')
        simple_ok = held[winner]['area_time_ratio'] < held[simple]['area_time_ratio']
        simple_ok &= against_simple['time_ratio_worst'] <= 1.03
        primary_ok &= simple_ok
        if not simple_ok:
            reasons.append('Modern policy does not retain the required held advantage over simple control')
    adopted = winner if primary_ok else simple if held[simple]['time_ratio_worst'] <= 1.03 else 'B0'
    reasons.append('Frozen development winner accepted' if primary_ok else f'Frozen fallback accepted: {adopted}')
    decision = {'status': 'held performance validated; safety and MicroBench tracked separately',
                'objective': 'whole-core area times equal-category geometric mean execution time',
                'selected_on_dev': winner, 'best_simple_on_dev': simple, 'adopted': adopted,
                'config': rows[adopted]['config'], 'qualified_mhz': rows[adopted]['mhz'],
                'area_um2': rows[adopted]['area_um2'], 'reasons': reasons,
                'common_mhz': protocol['common_mhz'],
                'memory_mode': protocol.get('memory_mode', 'cycle'),
                'fastest_on_dev': freeze['fastest'], 'smallest_on_dev': freeze['smallest'],
                'development': rows[adopted]['dev_own'], 'held': held[adopted],
                'held_sensitivity': {label: comparisons[label][adopted]
                                     for label in labels if label.startswith('held-sensitivity')},
                'measurement_hashes': hashes,
                'limitations': ['Post-synthesis STA; no routed timing or measured power',
                                'Best only within the declared matrix and tested 20 MHz grid',
                                'Standard-cell cache mapping; no SRAM macro comparison',
                                'AI software proxies, not model inference or MLPerf results',
                                'The reference RAM and SoC MicroBench memory models differ',
                                'MicroBench test is a regression, not a substitute for train']}
    (root / 'decision.json').write_text(json.dumps(decision, indent=2) + '\n')
    (root / 'comparisons.json').write_text(json.dumps(comparisons, indent=2) + '\n')
    with (root / 'case-results.csv').open('w') as stream:
        writer = csv.DictWriter(stream, fieldnames=list(cases[0]))
        writer.writeheader()
        writer.writerows(cases)
    summary = []
    best_score = rows[freeze['selected']]['area_time_ratio']
    for name, row in rows.items():
        same = comparisons[common][name]
        state = ('adopted' if name == adopted else 'failed frozen held rule' if name == winner
                 else 'preserved baseline' if name == 'B0' else 'experimental option, disabled by default')
        summary.append(dict(config=name, decision=state,
                            dev_score_relative_to_best=row['area_time_ratio'] / best_score, capacity_bytes=row['config'][0], ways=row['config'][1],
                            policy=row['config'][2], line_bytes=row['config'][3],
                            area_um2=row['area_um2'], qualified_mhz=row['mhz'],
                            common_mhz=protocol['common_mhz'],
                            common_cycle_ratio=same['cycle_ratio_gm'],
                            own_time_ratio=row['dev_own']['time_ratio_gm'],
                            area_time_ratio=row['area_time_ratio'],
                            common_instruction_beats_ratio=same['instruction_beats_ratio_gm']))
    with (root / 'configuration-results.csv').open('w') as stream:
        writer = csv.DictWriter(stream, fieldnames=list(summary[0]))
        writer.writeheader()
        writer.writerows(summary)
    table = ['| 配置 | 容量/路数/行 | 策略 | 面积 μm² | MHz | 同频周期比 | 合法频率用时比 | 面积×时间比 |',
             '| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |']
    for row in summary:
        table.append(f'| {row["config"]} | {row["capacity_bytes"]}/{row["ways"]}/{row["line_bytes"]} '
                     f'| {row["policy"]} | {row["area_um2"]:.0f} | {row["qualified_mhz"]} '
                     f'| {row["common_cycle_ratio"]:.4f} | {row["own_time_ratio"]:.4f} '
                     f'| {row["area_time_ratio"]:.4f} |')
    (root / 'configuration-table.md').write_text('\n'.join(table) + '\n')
    print('ACCEPT', adopted, decision['config'], decision['qualified_mhz'], 'MHz')
    print('HELD time', held[adopted]['time_ratio_gm'], 'area*time', held[adopted]['area_time_ratio'])


if __name__ == '__main__':
    main()
