#!/usr/bin/env python3
"""Attribute finite replacement policies; do not infer CPU time from accuracy."""
import hashlib
import json
import math
from pathlib import Path

NPC = Path(__file__).resolve().parents[2]
DOCS = NPC / 'docs/research/branch-v3'
POLICIES = {
    'rr': '满组轮转；命中不更新替换顺序',
    'lru_taken': '解析taken命中提升最近；新项插入最近',
    'lru_any': '所有解析命中提升最近，包含not-taken',
    'tree_plru': '二叉树近似LRU；分配/taken解析更新',
    'lip': '新项插入最不最近；taken解析命中提升最近',
    'bip': '通常按LIP插入；每32次分配有1次插入最近',
    'dip': '两个leader组在LRU/BIP间学习，其他组跟随选择器',
    'srrip': '两位RRPV；新项2、taken解析命中0、替换最大值',
    'rrip_i3': 'SRRIP的新项固定3，单独隔离低优先级插入',
    'brrip': '新项通常3、每32次分配有1次为2',
    'drrip': '两个leader组在SRRIP/BRRIP间学习',
    'ship_resolve': '16项PC签名复用表学习新项应插入2还是3',
    'rrip_retire_taken': '新项2；实际taken控制流退休后才提升0',
    'rrip_retire_useful': '新项2；正确采用taken预测且退休才提升0',
}
DIRECTIONS = ('BHT16', 'TAGE', 'TAGE_SC_Loop')
PREFILLS = ('none', 'all', 'backward', 'confidence3', 'all_low_priority')
PEAK_FIELDS = ('query_snapshots_max', 'retirement_snapshots_max')


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def state_bits(config):
    """Straightforward logical state, excluding ports and existing direction/RAS."""
    entries, ways = config['entries'], config['ways']
    sets = entries // ways
    set_bits, way_bits = sets.bit_length() - 1, ways.bit_length() - 1
    payload = entries * (30 - set_bits + 1 + 2 + config['target_bits'])
    policy = config['policy']
    if policy == 'rr':
        replacement = sets * way_bits
    elif policy == 'tree_plru':
        replacement = sets * (ways - 1)
    elif policy.startswith('lru_') or policy in ('lip', 'bip', 'dip'):
        # Two-way LRU has a one-bit equivalent; four-way models use ranks.
        replacement = sets if ways == 2 else entries * way_bits
    else:
        replacement = entries * 2
    extra = 5 if policy in ('bip', 'brrip') else 10 if policy in ('dip', 'drrip') else 0
    if policy == 'ship_resolve':
        extra = entries + 16 * 2
    retirement = policy.startswith('rrip_retire_')
    generation = entries * 4 if retirement else 0
    token = (set_bits + way_bits + 4 + 2) if retirement else 0
    hints = 4 * (32 + 32 + 2) + 7 if config['prefill'] != 'none' else 0
    metadata = 256 * 24 if hints else 0
    return {
        'table_payload_bits': payload, 'replacement_bits': replacement,
        'extra_policy_bits': extra, 'generation_bits': generation,
        'target_table_and_policy_bits': payload + replacement + extra + generation,
        'retirement_token_bits_per_flight': token,
        'retirement_token_budget_bits': token * 16,
        'hint_queue_bits': hints, 'complete_line_metadata_bits': metadata,
        'estimated_state_bits': payload + replacement + extra + generation + token * 16 + hints + metadata,
        'excluded': 'read/write selection, hashes, extra BHT read for confidence hints, pipeline token transport, arbitration, ports, direction/RAS; not cell area',
    }


def aggregate(records, index):
    rows = [record['counts'][index] for record in records]
    assert all(row['id'] == index for row in rows)
    result = {key: sum(row[key] for row in rows)
              for key in rows[0] if key not in ('id', 'selector_final', *PEAK_FIELDS)}
    result.update({key: max(row[key] for row in rows) for key in PEAK_FIELDS})
    result['selector_final_by_input'] = {record['case']: row['selector_final']
                                        for record, row in zip(records, rows)}
    return result


def compare(records, candidate, reference):
    paired = {}
    families = {}
    for record in records:
        now = record['counts'][candidate]['next_pc_errors']
        old = record['counts'][reference]['next_pc_errors']
        ratio = now / old
        paired[record['case']] = 100 * (ratio - 1)
        families.setdefault(record['family'], []).append(ratio)
    means = [sum(values) / len(values) for values in families.values()]
    return {
        'per_input_error_change_percent': paired,
        'worst_input_error_change_percent': max(paired.values()),
        'improved_inputs': sum(value < 0 for value in paired.values()),
        'regressed_inputs': sum(value > 0 for value in paired.values()),
        'equal_family_geomean_error_ratio': math.exp(sum(math.log(value) for value in means) / len(means)),
    }


def main():
    contract_path = DOCS / 'btb-replacement-contract.json'
    source_path = DOCS / 'btb-replacement-models.json'
    contract = json.loads(contract_path.read_text())
    model = json.loads(source_path.read_text())
    assert model['contract_sha256'] == sha(contract_path)
    records, configs = model['records'], contract['configs']
    assert len(configs) == 420 and len(records) == 14
    names = {config['name']: index for index, config in enumerate(configs)}
    assert len(names) == len(configs)
    results = {}
    for index, config in enumerate(configs):
        topology = config['name'].split('/')[0]
        reference_name = f"{topology}/srrip/none/{config['direction']}"
        count = aggregate(records, index)
        control = aggregate(records, names[reference_name])
        assert count['branches'] == control['branches'] and count['conditional'] == control['conditional']
        assert count['direction_errors'] == control['direction_errors']
        accuracy = 100 * (1 - count['next_pc_errors'] / count['branches'])
        results[config['name']] = {
            'config': config, 'counts': count,
            'next_pc_accuracy_percent': accuracy,
            'taken_target_accuracy_percent': 100 * (1 - (count['target_absent'] + count['target_wrong']) / count['taken']),
            'same_topology_srrip_control': reference_name,
            'error_change_vs_control_percent': 100 * (count['next_pc_errors'] / control['next_pc_errors'] - 1),
            **compare(records, index, names[reference_name]), 'state': state_bits(config),
        }
    direction = {}
    for name in DIRECTIONS:
        count = results['full32/srrip/none/' + name]['counts']
        direction[name] = {'conditional': count['conditional'], 'errors': count['direction_errors'],
                           'accuracy_percent': 100 * (1 - count['direction_errors'] / count['conditional'])}
    summary = {
        'schema': 1, 'contract_sha256': sha(contract_path), 'models_sha256': sha(source_path),
        'inputs': len(records), 'families': len({r['family'] for r in records}),
        'joint_configurations': len(configs), 'policy_count': len(POLICIES),
        'baseline_query_checks': sum(record['baseline_query_checks'] for record in records),
        'scope': model['scope'], 'direction': direction, 'results': results,
        'limits': model['limits'],
    }
    (DOCS / 'btb-replacement-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    lines = [
        '# BTB替换、插入与反馈：扩展实验', '',
        '2026-10-02。此前RTL只比较轮转、两路LRU和SRRIP，确实不足以解释全部替换行为。本轮先冻结14种策略、六种组织、五种预填充模式及三种方向控制，共420点；同一预填充完整矩阵只在32项组织运行，其余组织不预填充。使用原有14个开发输入，没有运行train或重新打开最终保留集。', '',
        '## 比较的策略', '',
        '| 模型策略 | 实际规则 |', '| --- | --- |']
    lines += [f'| {name} | {rule} |' for name, rule in POLICIES.items()]
    lines += ['',
              '所有查询只读；LRU按解析命中更新，不是取指访问LRU。BRRIP/BIP的1/32由五位分配计数确定，避免不同随机序列影响配对。DIP/DRRIP只有两个leader组，五位选择器在解析新分配时更新，预填充不训练选择器。SHiP式表为16项二位计数器，签名由分支PC折叠；taken解析命中学习复用，从未复用的受害者提供负反馈。', '',
              '退休taken在解析后保存住户身份；退休useful保存查询时住户身份，必须确实采用正确的taken目标才提升。两者检查组、路、PC及四位generation；解析写口优先，冲突时丢掉优化反馈，不等待、不阻塞CPU。软件另存无限版本号检查本组输入中是否发生有限generation误匹配；这不是任意程序下已经证明的生命周期安全。', '',
              '## 同组织、同方向结果', '',
              '下表固定完整32项/4路、全部高位折叠索引、新条件分支仅taken准入、无预填充，方向为缩放TAGE＋SC＋Loop。统计窗口有632,793条控制流，其中578,760条条件分支、419,947次taken。错误变化与同组织SRRIP比较，最差输入按各自错误数计算。', '',
              '| 策略 | 下一PC错误数 | 下一PC准确率 | 错误数变化 | 最差输入变化 | 目标缺项 / 已命中但目标错误 | BTB及策略状态位 |',
              '| --- | ---: | ---: | ---: | ---: | ---: | ---: |']
    for policy in POLICIES:
        row = results[f'full32/{policy}/none/TAGE_SC_Loop']
        count = row['counts']
        lines.append(f"| {policy} | {count['next_pc_errors']:,} | {row['next_pc_accuracy_percent']:.3f}% | {row['error_change_vs_control_percent']:+.3f}% | {row['worst_input_error_change_percent']:+.3f}% | {count['target_absent']:,} / {count['target_wrong']:,} | {row['state']['target_table_and_policy_bits']:,} |")
    lines += ['', '状态位只计tag/目标/有效/kind及算法状态，退休方案的在途token还未计入这一列；不是综合面积。不同策略的方向错误都保持30,059次，目标组织不会在此固定事件模型里改变隔离的方向统计。', '',
              '16项/4路折叠组织下，SHiP式策略分别把BHT、纯TAGE、TAGE＋SC＋Loop的下一PC错误从101,447→99,644、77,716→74,180、78,647→75,164；最后一组减少4.429%，14个输入均改善，最弱改善0.983%。只比相同组织SRRIP；不是把折叠索引或容量收益归给SHiP。', '',
              '到了32项，同一SHiP式策略只减少1.143%，最差输入增加19.554%；64项反而增加4.161%。小表学习能保留部分热目标，签名别名和插入压力仍可能伤害更大表的已有工作集。不能从某个容量的正结果宣布全局最优。', '',
              '退休useful在32项减少0.824%，最差输入增加0.182%；退休taken增加5.678%。实际taken不是正确且被利用的预测，两种反馈不能混称“退休反馈”。更少下一PC错误也不一定意味着目标缺项更少：不保留低价值条件目标可能避免错误taken，仍须同时看缺项、错误目标及方向门控。', '',
              '## 预填充、插入优先级和方向联合', '',
              '模式none不预填充；all使用实际完整安装行中的B/J；backward只取后向条件与JAL；confidence3只在当前BHT16计数为3时采用条件提示，JAL保留；all_low_priority与all有相同提示来源和队列，仅改变插入优先级。队列四项、每拍最多一次空闲写、不能覆盖已有住户；解析训练优先，其次是有效退休反馈。', '',
              '表内为TAGE＋SC＋Loop的下一PC错误数。每一列的简单对照保持相同结构，不能把低优先级插入和新增预填充队列的作用合并。', '',
              '| 策略 | none | all | backward | confidence3 | all_low_priority |',
              '| --- | ---: | ---: | ---: | ---: | ---: |']
    for policy in ('rr', 'tree_plru', 'bip', 'srrip', 'brrip', 'drrip', 'ship_resolve', 'rrip_retire_taken', 'rrip_retire_useful'):
        values = [f"{results[f'full32/{policy}/{mode}/TAGE_SC_Loop']['counts']['next_pc_errors']:,}" for mode in PREFILLS]
        lines.append('| ' + policy + ' | ' + ' | '.join(values) + ' |')
    lines += ['',
              'SRRIP普通预填充从51,725错增至58,133；同提示低优先级插入降至52,110，缓解了污染但仍比不预填充多0.744%。轮转在两种插入模式下完全相同，是无优先级状态的对照。', '',
              'BRRIP＋置信过滤为50,782错，比无预填充SRRIP少1.823%，但最差输入多14.795%；不能只看汇总。退休useful＋低优先级预填充为50,622错，少2.132%、最差多1.100%，但有65,691次提示新分配、53,868个未解析复用的提示受害者，且65,691中只有3,069个得到可观测退休正确目标信用。引入metadata/队列与身份反馈的成本远大于单独替换位。', '',
              '## 成本、前提与取舍', '',
              '- SRRIP是每条两位；四路PLRU每组三位，状态更少，但32项下错误多3.807%。LRU/LIP/BIP按四路rank实现每条两位；BIP另加五位相位，DIP再加五位选择器。BRRIP只比SRRIP多五位，DRRIP再加五位。',
              '- SHiP式策略比SRRIP增加32位签名表和每条一个复用位；16项共多48位。受害者签名可从tag和索引恢复完整PC再计算，不需要重复保存签名。组合hash、计数读/写选择仍须综合和STA检查。',
              '- 退休方案另需每条四位generation，以及16份在途token预算；32项时为128位generation和176位token。PC沿已有指令载荷，反馈端还需要端口仲裁与身份比较。当前冲突丢信用，不新增等待。',
              '- 所有预填充按完整行来源保守计6144位指令metadata和271位四项队列，未计额外身份访问端口。confidence3还需查询其他PC的BHT读取能力，不能假定免费或使用TAGE输出伪造置信度。',
              '- DIP/DRRIP的组数只有4/8/16，两个leader很容易受地址分布影响；本模型保留这一真实约束，不借大型LLC的平衡样本结论。选择器最终值及leader分配次数均保留在逐输入数据中。', '',
              '冻结的RTL追加对照见`btb-replacement-rtl-matrix.json`：选择16项/4路折叠的SHiP式原型，与完全相同方向/组织的SRRIP分别运行，不再据最终保留集调参。模型表本身不是700MHz签核或面积×时间结论；追加RTL的完整测量见[RTL匹配对照](btb-replacement-rtl-study.md)与`btb-replacement-rtl-results.json`。稳定默认配置不变。', '',
              '## 文献的实际借鉴', '',
              '- [DIP/LIP/BIP，Qureshi等，ISCA 2007](https://jaleels.org/ajaleel/publications/isca2007-dip.pdf)：原评测包含1MiB/16路L2和乱序核；借鉴插入与命中提升分开、周期性高优先级插入、组竞争。本核把访问改为解析事件，缩小选择器，原论文收益不能套用。',
              '- [RRIP，Jaleel等，ISCA 2010](https://jaleels.org/ajaleel/publications/isca2010-rrip.pdf)：原对象是MiB级LLC；借鉴RRPV、SRRIP/BRRIP和组竞争，修改为BTB的taken解析复用。本轮单独列插入3对照，不把改变插入值称作新预测算法。',
              '- [SHiP，Wu等，MICRO 2011作者论文](https://jaleels.org/ajaleel/publications/micro2011-SHiP.pdf)：原评测包括1MiB LLC和四核共享4MiB LLC，研究PC/地址区域/路径签名与复用。本核改为分支PC签名、16个二位计数、解析taken命中与未复用替换反馈；不是原LLC算法等价复刻。',
              '- [SmartScout，ICS 2026作者页面](https://craft.cs.tsinghua.edu.cn/publication/look-before-you-leap-precision-instruction-supply-via-smartscout/)：只核验摘要中的运行时过滤和验证时间思路；confidence3是单独的简化过滤对照，没有实现FTQ验证松弛机制，不能称为SmartScout实现。', '',
              '前三项是有影响的经典研究，不是近年的新论文。近期方法需要更完整的原文/artifact和系统前提后才能移植，本轮不把经典策略换名冒充前沿机制。', '',
              '## 核验与复现', '',
              '420×14组输入完成；3,234,632次基线真实BTB查询及BHT状态逐次一致。每个输入有18组与此前独立Python联合模型的交叉核对，基线下一PC错误与RTL实际计数相同。轮转、SRRIP、两路LRU与旧模型全状态随机对照及新增策略定向/随机检查共2,960,000次通过。', '',
              '计数窗口与完整自然前缀分开：branches/errors只在ROI汇总，插入、替换、信用和提示复用统计包含前缀。该组窗口共退休2,384,137条指令，冷/暖有重叠；不是独立大规模性能评测。固定查询/解析/I$驻留无法重建候选的错误路径、周期或流量。提示使用真实安装后数据，不能提前读全程序指令或未来分支真值。', '',
              '命令、源代码、输入、日志和压缩证据索引见[入口](README.md#btb替换策略扩展)。逐点/逐输入原始计数见[模型结果](btb-replacement-models.json)，比率和状态位见[汇总](btb-replacement-summary.json)。本页由`summarize_replacement_study.py`生成，原最终选择以`final-results.json`为准。', '']
    (DOCS / 'btb-replacement-study.md').write_text('\n'.join(lines))
    print('SUMMARIZED', len(records), 'inputs,', len(configs), 'points and', len(POLICIES), 'policies')


if __name__ == '__main__':
    main()
