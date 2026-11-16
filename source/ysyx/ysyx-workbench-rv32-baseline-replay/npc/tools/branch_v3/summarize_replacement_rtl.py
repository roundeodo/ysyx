#!/usr/bin/env python3
"""Compare a matched replacement pair using logs and qualified STA frequencies."""
import hashlib
import json
import math
from pathlib import Path
import re

NPC = Path(__file__).resolve().parents[2]
ROOT = NPC / 'result/branch-v3'
DOCS = NPC / 'docs/research/branch-v3'
NAMES = ('NSL-BT16-RRIP-replacement', 'NSL-BT16-SHiP-replacement')


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def cases(name, mhz):
    measurements = {}
    for suffix, images in [('dev', 'images'), ('streams', 'streams-development')]:
        manifest = json.loads((ROOT / images / 'manifest.json').read_text())
        input_identity = {case['name']: case for case in manifest['cases']}
        label = f'{name}-{suffix}' + (f'-{mhz}' if mhz != 700 else '')
        directory = ROOT / 'rtl' / label
        index = json.loads((directory / 'index.json').read_text())
        for invocation in index:
            case_name = invocation['name']
            image = input_identity[case_name]
            assert not image['held']
            assert f'+cpu_mhz={mhz}' in invocation['command']
            assert '+latency_ns=100' in invocation['command'] and '+beat_ns=10' in invocation['command']
            log = directory / (case_name + '.log')
            assert sha(log) == invocation['log_sha256']
            assert 'PASS proxy' in log.read_text()
            values = {key: int(value, 16 if key in ('checksum', 'digest') else 10)
                      for key, value in re.findall(r'(\w+)=([0-9a-fA-F]+)', '\n'.join(
                          line for line in log.read_text().splitlines() if line.startswith(('RESULT ', 'COUNTERS ', 'DETAIL '))))}
            values['ex_recoveries'] = values['conditional_errors'] + values['target_errors']
            family = case_name.split('-')[0]
            measurements[case_name] = {
                'family': family, 'values': values, 'mhz': mhz,
                'time_seconds': values['cycles'] / (mhz * 1e6),
                'ipc': values['retired'] / values['cycles'],
                'image_sha256': image['hashes']['image.bin'],
                'log': str(log.relative_to(NPC)), 'log_sha256': sha(log),
                'binary_sha256': invocation['binary_sha256'],
            }
    assert len(measurements) == 14
    return measurements


def compare(now, base, area_ratio=1.0):
    assert set(now) == set(base)
    paired, groups = {}, {}
    for case, candidate in now.items():
        reference = base[case]
        assert candidate['image_sha256'] == reference['image_sha256']
        for key in ('retired', 'all_retired', 'digest', 'checksum', 'branches', 'nonbranch_errors'):
            assert candidate['values'][key] == reference['values'][key], (case, key)
        ratio = candidate['time_seconds'] / reference['time_seconds']
        groups.setdefault(candidate['family'], []).append(ratio)
        paired[case] = {'time_ratio': ratio, 'time_change_percent': 100 * (ratio - 1),
                        'area_time_ratio': ratio * area_ratio,
                        'cycles_ratio': candidate['values']['cycles'] / reference['values']['cycles']}
    family_means = {family: sum(values) / len(values) for family, values in groups.items()}
    ratio = math.exp(sum(math.log(value) for value in family_means.values()) / len(family_means))
    return {'per_input': paired, 'family_mean_time_ratios': family_means,
            'equal_family_geomean_time_ratio': ratio,
            'equal_family_area_time_ratio': ratio * area_ratio,
            'worst_input_time_change_percent': max(row['time_change_percent'] for row in paired.values())}


def counts(measurements):
    keys = ('cycles', 'retired', 'ex_recoveries', 'conditional_errors', 'target_errors',
            'nonbranch_errors', 'misses', 'i_bursts', 'i_beats', 'd_beats', 'data_wait',
            'frontend_wait', 'd_wait', 'btb_missing', 'direction', 'target')
    return {key: sum(row['values'][key] for row in measurements.values()) for key in keys}


def main():
    configs = json.loads((DOCS / 'btb-replacement-rtl-matrix.json').read_text())
    assert {key: value for key, value in configs[NAMES[0]].items() if key != 'target_policy'} == {
        key: value for key, value in configs[NAMES[1]].items() if key != 'target_policy'}
    qualified = {name: json.loads((ROOT / 'ppa' / name / 'qualified.json').read_text()) for name in NAMES}
    common_mhz = min(row['mhz'] for row in qualified.values())
    for name in NAMES:
        timing = json.loads((ROOT / 'ppa' / name / 'timing.json').read_text())
        if str(common_mhz) not in timing:
            timing.update({str(common_mhz): json.loads((ROOT / 'ppa' / name / f'probe-{common_mhz}.json').read_text())})
        assert timing[str(common_mhz)]['passed'] and qualified[name]['all_groups_passed']
    common = {name: cases(name, common_mhz) for name in NAMES}
    own = {name: cases(name, qualified[name]['mhz']) for name in NAMES}
    profiling = {name: cases(name, 700) for name in NAMES}
    area_ratio = qualified[NAMES[1]]['area_um2'] / qualified[NAMES[0]]['area_um2']
    unit_log = ROOT / 'btb-unit-replacement/run.log'
    assert 'PASS BTB configs=53' in unit_log.read_text()
    safety_path = ROOT / 'safety' / NAMES[1] / 'results.json'
    safety = json.loads(safety_path.read_text())
    assert len(safety) == 4 and not any(row['returncode'] for row in safety)
    isa_path = ROOT / 'isa/difftest/results.json'
    isa = json.loads(isa_path.read_text())
    candidate_isa = [row for row in isa['records'] if row['config'] == NAMES[1]]
    assert len(candidate_isa) == 10
    for row in candidate_isa:
        log = ROOT / 'isa/difftest' / NAMES[1] / (row['test'] + '.log')
        assert 'HIT GOOD TRAP' in log.read_text() and 'ABORT' not in log.read_text()
    random_results = []
    for seed in (137, 271):
        directory = ROOT / 'rtl' / f'{NAMES[1]}-random{seed}'
        random_results.append({'seed': seed, 'index': str((directory / 'index.json').relative_to(NPC)),
                               'index_sha256': sha(directory / 'index.json')})
    results = {
        'schema': 1, 'configs': configs, 'stable_default_changed': False,
        'scope': 'Additional development only; fixed 100ns shared AXI first response/10ns beat, RV32I, same cache and backend. Not native SoC time or a new final holdout.',
        'common_mhz': common_mhz, 'area_ratio': area_ratio,
        'ppa': qualified, 'same_legal_frequency': compare(common[NAMES[1]], common[NAMES[0]], area_ratio),
        'own_qualified_frequency': compare(own[NAMES[1]], own[NAMES[0]], area_ratio),
        'profiling_700_not_signoff': compare(profiling[NAMES[1]], profiling[NAMES[0]], area_ratio),
        'counts_at_common_frequency': {name: counts(rows) for name, rows in common.items()},
        'counts_at_700_profile': {name: counts(rows) for name, rows in profiling.items()},
        'common_cases': common, 'own_frequency_cases': own,
        'verification': {'unit_log': str(unit_log.relative_to(NPC)), 'unit_log_sha256': sha(unit_log),
                         'safety': safety, 'safety_sha256': sha(safety_path),
                         'difftest': candidate_isa, 'reference_sha256': isa['reference_sha256'],
                         'random_memory': random_results},
        'decision': {'matched_control_retained': True, 'prototype_default_enabled': False,
                     'reason': 'Measured area growth exceeds equal-family time reduction; no new final holdout qualification.'},
        'limits': ['Standard-cell mapping with AREA 3 at 820MHz, setup/hold/gating STA; no place/route or power measurement.',
                   'The 20MHz grid is a measured qualifying point, not exact silicon Fmax.',
                   'Development pair was selected after the finite model; no final held data reopened. No claim of final best policy.'],
    }
    (DOCS / 'btb-replacement-rtl-results.json').write_text(json.dumps(results, indent=2) + '\n')
    lines = ['# BTB签名复用学习：RTL匹配对照', '',
             '追加开发集实验；固定共享AXI首响应100ns、后续beat10ns。RV32I、cache与后端相同；不是原生SoC计时，也没有重新打开最终保留集。', '',
             '同为16项/4路/折叠索引/taken新条件准入和TAGE＋SC＋Loop，唯一参数差别是BTB policy2→4。I$1KiB/4路/32B/policy13、D$256B/2路/16B和后端保持相同。原默认policy0未改。', '',
             '| 配置 | 整核mapped cell area | 20MHz网格通过频率 |', '| --- | ---: | ---: |']
    for name, row in qualified.items():
        lines.append(f"| {name} | {row['area_um2']:,.3f} μm² | {row['mhz']}MHz |")
    lines += ['', f"整核面积变化{100 * (area_ratio - 1):+.3f}%。额外算法状态只有48位，但mux、hash、写反馈、时钟/复位及全核mapping变化也计入实际面积，不能按位数直接换算。", '',
              '| 比较口径 | 七类等权配对时间变化 | 面积×时间变化 | 最差单输入时间变化 |', '| --- | ---: | ---: | ---: |']
    for label, key in [('共同合法频率', 'same_legal_frequency'), ('各自通过频点', 'own_qualified_frequency')]:
        row = results[key]
        lines.append(f"| {label} | {100 * (row['equal_family_geomean_time_ratio'] - 1):+.3f}% | {100 * (row['equal_family_area_time_ratio'] - 1):+.3f}% | {row['worst_input_time_change_percent']:+.3f}% |")
    lines += ['', f'共同合法频率为{common_mhz}MHz；各频率实际重跑，存储首响应固定100ns、beat固定10ns并换算成相应CPU周期，未只按频率比例缩放旧周期。相同14输入的retired/all_retired/digest/checksum/branches/nonbranch_errors逐项一致。', '',
              '| 输入 | 时间变化 | SRRIP周期 | SHiP式周期 | SRRIP I$miss | SHiP式 I$miss |',
              '| --- | ---: | ---: | ---: | ---: | ---: |']
    for case in sorted(common[NAMES[0]]):
        base, new = common[NAMES[0]][case]['values'], common[NAMES[1]][case]['values']
        change = results['same_legal_frequency']['per_input'][case]['time_change_percent']
        lines.append(f"| {case} | {change:+.3f}% | {base['cycles']:,} | {new['cycles']:,} | {base['misses']:,} | {new['misses']:,} |")
    base_count, new_count = (results['counts_at_common_frequency'][name] for name in NAMES)
    ex_change = 100 * (new_count['ex_recoveries'] / base_count['ex_recoveries'] - 1)
    miss_change = 100 * (new_count['misses'] / base_count['misses'] - 1)
    lines += ['', '## 收益归因与限制', '',
              f"共同频点EX纠错{base_count['ex_recoveries']:,}→{new_count['ex_recoveries']:,}（{ex_change:+.3f}%），I$miss {base_count['misses']:,}→{new_count['misses']:,}（{miss_change:+.3f}%），数据总线beat保持{base_count['d_beats']:,}。", '',
              f"纠错原因进一步分解：BTB缺项{base_count['btb_missing']:,}→{new_count['btb_missing']:,}，命中后的方向错误{base_count['direction']:,}→{new_count['direction']:,}，命中后的目标错误{base_count['target']:,}→{new_count['target']:,}。缺项减少，但有些增加的命中采用了错误方向或旧目标，不能把每次新增命中都算作收益。", '',
              'EX纠错下降不会按同一比例变成执行时间下降。json_bpe、runtime_graph等会因为不同错误取指路径改变I$驻留与AXI竞争；本组需要同时看miss、总线beat和等权时间，不能只以误预测数选型。', '',
              '此前700MHz运行仅作周期/预测分析，是否满足时序以本页STA为准；16项完整方向系统不等于原BHT16/BTB16稳定默认或之前32项组织。源码差异、配置、工具和原始报告均保留，不能把不同组织的最高频率当作同一基线。', '',
              '已通过53种BTB组织/参数的1,908,000次查询、41,472,000次状态检查，包含SHiP签名counter、复用位和RRPV；模型按完整PC存储，与RTL的tag/索引反解独立。安全回归包含取指反压、FENCE.I、D$写回错误恢复和精确异常；10个NEMU DiffTest程序及真实jsmn/miniz的两个随机总线种子通过。断言和原参考均保留。', '',
              '按本轮面积×时间准则，SHiP式原型的约0.413%时间收益未抵消约1.011%面积增长，因此在这组匹配对照中保留SRRIP。保留policy4供研究复现，默认不启用；这只否决已测的小组织，不否决所有签名学习或其他容量。', '',
              '没有重新测试最终保留组或原生SoC大负载，也没有功耗/P&R签核。两种16项组织的680MHz均失败、660MHz均通过；SHiP式700MHz还存在数据及门控setup违例，不能用700MHz仿真参数宣布700MHz签核，也不能据此否决已经在其他组织通过700MHz的TAGE/SC/Loop。原论文出处与420点模型结果见[扩展研究](btb-replacement-study.md)，逐项数据和日志身份见[机器结果](btb-replacement-rtl-results.json)。', '']
    (DOCS / 'btb-replacement-rtl-study.md').write_text('\n'.join(lines))
    print('SUMMARIZED matched RTL pair at', common_mhz, 'MHz; area ratio', area_ratio)


if __name__ == '__main__':
    main()
