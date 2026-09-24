#!/usr/bin/env python3
"""Export compact machine-readable evidence and tables after the full audit."""
import argparse
import csv
import json
import math
from pathlib import Path
import shutil
from explore_frontend import sha


def read(path):
    return json.loads(path.read_text())


def delta(ratio):
    return f'{(ratio - 1) * 100:+.2f}%'


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    a = p.parse_args()
    root, out = a.root.resolve(), a.output.resolve()
    assert read(root / 'audit.json')['status'] == 'passed'
    assert (root / 'microbench-legal-complete.json').exists()
    out.mkdir(parents=True, exist_ok=False)
    dev = read(root / 'development-summary.json')
    held = read(root / 'held-summary.json')
    decision = read(root / 'held-decision.json')
    records = []
    for name, data in dev['configurations'].items():
        record = {'name': name, 'mhz': data['ppa']['mhz'], 'area_um2': data['ppa']['area_um2'],
                  'common_mhz': dev['common_mhz'],
                  'common_time_ratio': data['common']['time_ratio_gm'],
                  'own_time_ratio': data['own']['time_ratio_gm'],
                  'own_adp_ratio': data['own']['adp_ratio'],
                  'dev_max_input_ratio': data['own']['max_input_time_ratio'],
                  'held_time_ratio': held[name]['time_ratio_gm'],
                  'held_adp_ratio': held[name]['adp_ratio'],
                  'held_max_input_ratio': held[name]['max_input_time_ratio']}
        records.append(record)
    with (out / 'comparison.csv').open('w') as stream:
        writer = csv.DictWriter(stream, fieldnames=list(records[0]))
        writer.writeheader()
        writer.writerows(records)
    lines = ['| 配置 | 面积 μm² | 合法 MHz | 同频时间变化 | 各自频点时间变化 | 开发ADP变化 | 保留ADP变化 |',
             '| --- | ---: | ---: | ---: | ---: | ---: | ---: |']
    for row in records:
        lines.append(f'| {row["name"]} | {row["area_um2"]:.3f} | {row["mhz"]} | '
                     f'{delta(row["common_time_ratio"])} | {delta(row["own_time_ratio"])} | '
                     f'{delta(row["own_adp_ratio"])} | {delta(row["held_adp_ratio"])} |')
    (out / 'comparison.md').write_text('\n'.join(lines) + '\n')
    integration_area = read(root / 'ppa/B0current/qualified.json')['area_um2']
    infrastructure_control = {
        row['name']: {'area_ratio_vs_default_off_rtl': row['area_um2'] / integration_area,
                      'adp_ratio_vs_default_off_rtl': row['own_time_ratio'] * row['area_um2'] / integration_area}
        for row in records if row['name'] != 'B0'}
    common_label = dev['common_label']
    base_rows = {row['case']['name']: row for row in read(root / 'rtl' / common_label / 'B0/results.json')['results']}
    traffic = {}
    for name in dev['configurations']:
        family = {}
        rows = read(root / 'rtl' / common_label / name / 'results.json')['results']
        for row in rows:
            reference = base_rows[row['case']['name']]
            family.setdefault(row['case']['kind'], []).append(row['counters']['i_beats'] / reference['counters']['i_beats'])
        families = {kind: math.exp(sum(map(math.log, values)) / len(values)) for kind, values in family.items()}
        traffic[name] = {'i_beats_ratio_gm': math.exp(sum(map(math.log, families.values())) / len(families)),
                         'i_beats_families': families,
                         'd_transfer_cycles_same': all(row['counters']['d_beats'] == base_rows[row['case']['name']]['counters']['d_beats'] for row in rows)}
    summary = {'decision': decision, 'common_mhz': dev['common_mhz'], 'comparison': records,
               'same_infrastructure_control': infrastructure_control, 'traffic_at_common_clock': traffic,
               'default_integration': read(root / 'default-integration.json'),
               'microbench_legal': {name: read(root / 'microbench-legal' / name / 'report.json')
                                   for name in ['B0current', 'G128']},
               'limits': ['RV32I software proxies, not full model inference',
                          'mapped cell/latch area and pre-layout STA, not silicon measurements',
                          '660 MHz G128 and B128 diagnostics are not qualified hardware operating points',
                          'perfect prediction is a simulation diagnostic, not an implementable candidate',
                          'MicroBench test only; train was not rerun',
                          'D traffic counter records transfer cycles, not exact total beats; no power measured']}
    (out / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    files = ['baseline-manifest.json', 'configurations.json', 'toolchain.json', 'selection-freeze.json',
             'development-summary.json', 'held-summary.json', 'held-decision.json', 'audit.json',
             'evaluation-complete.json', 'cache-interaction.json', 'default-integration.json',
             'image-reproduction.json', 'model/results.json', 'model/functions.json',
             'diagnostics/results.json', 'history-observer/G128/results.json',
             'sensitivity-fast.json', 'sensitivity-slow.json', 'sensitivity-random.json',
             'verification/direction-first/results.json', 'difftest/results.json',
             'images/manifest.json', 'images-reproduction/manifest.json',
             'microbench-legal-complete.json', 'execution-sources.json']
    files += [str(path.relative_to(root)) for path in sorted((root / 'ppa').glob('*/*.json'))]
    files += [str(path.relative_to(root)) for path in sorted((root / 'rtl').glob('*/*/results.json'))]
    files += [str(path.relative_to(root)) for path in sorted((root / 'builds').glob('*/*.json'))]
    files += [str(path.relative_to(root)) for path in sorted((root / 'verification').glob('*/manifest.json'))]
    for section in ['microbench', 'microbench-legal']:
        files += [str(path.relative_to(root)) for path in sorted((root / section).glob('*/*.json'))]
    for relative in files:
        target = out / 'evidence' / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / relative, target)
    # Logs remain under result; this index binds their contents without copying netlists/objects.
    logs = {}
    for path in sorted(root.rglob('*.log')):
        if not path.is_file():
            continue
        logs[str(path.relative_to(root))] = {'sha256': sha(path), 'bytes': path.stat().st_size}
    (out / 'raw-log-index.json').write_text(json.dumps({'root': str(root), 'logs': logs}, indent=2) + '\n')
    (out / 'README.md').write_text(
        '# 分支预测补充探索数据\n\n'
        f'开发选择：{decision["development_choice"]}；保留验证后的建议：{decision["recommendation"]}。\n\n'
        '`summary.json`和`comparison.csv`是汇总；`evidence`保存配置、来源哈希及逐项结果。\n'
        '`raw-log-index.json`指向保留的原始日志，包括失败尝试；未把它们当成通过记录。\n'
        f'统一合法频点为{dev["common_mhz"]} MHz。早期660 MHz数据保留为功能诊断，不能替代未通过STA配置的硬件时间。\n', encoding='utf-8')
    print('PASS report exported', out)


if __name__ == '__main__':
    main()
