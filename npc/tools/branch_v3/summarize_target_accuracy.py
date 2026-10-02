#!/usr/bin/env python3
"""Summarize finite target models without changing the recorded experiments."""
import hashlib
import json
from pathlib import Path
import re

from target_models import Btb

NPC = Path(__file__).resolve().parents[2]
DOCS = NPC / 'docs/research/branch-v3'
SOURCE = DOCS / 'target-accuracy-models.json'
DIRECTIONS = ('BHT16', 'TAGE', 'TAGE_SC_Loop')


def accuracy(correct, total):
    return 100 * correct / total


def resources(name, table_bits):
    # Payload estimates exclude direction/RAS, ports, decoders and flight state.
    metadata = 256 * (3 if name == 'predecode_type' else 24) if name.startswith('predecode') else 0
    # Conservative complete-line predecode source for the implemented prefill
    # contract. A beat-wise decoder would need a separate timing experiment.
    if name.startswith('prefill'):
        metadata = 256 * 24
    queue = 4 * (32 + 32 + 2) + 2 + 2 + 3 if name.startswith('prefill') else 0
    fast = Btb(entries=4, ways=2, index=0, policy=0, admission=1).bits if name.startswith('tier') else 0
    return {'target_table_bits': table_bits, 'fast_table_bits': fast,
            'instruction_metadata_bits': metadata, 'prefill_queue_bits': queue,
            'estimated_payload_bits': table_bits + fast + metadata + queue,
            'excluded': 'direction/RAS, independent cache identity/read ports, flight state, decode/arbitration logic; not mapped cell area'}


def main():
    study = json.loads(SOURCE.read_text())
    assert len(study['records']) == 14 and len(study['counts']) == 54
    state = study['records'][0]['target_state_bits']
    summary = {'source_sha256': hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
               'inputs': len(study['records']), 'joint_configurations': len(study['counts']),
               'baseline_query_checks': sum(row['query_checks'] for row in study['records']),
               'scope': study['scope'], 'direction': {}, 'target': {},
               'resources': {name: resources(name, bits) for name, bits in state.items()}}
    windows = {}
    for label in ('B0-target-model-20261002-dev', 'B0-target-model-20261002-streams'):
        for log in (NPC / 'result/branch-v3/rtl' / label).glob('*.log'):
            result = next(line for line in log.read_text().splitlines() if line.startswith('RESULT '))
            cycles, retired = map(int, re.search(r'cycles=(\d+) retired=(\d+)', result).groups())
            windows[log.stem] = {'baseline_cycles': cycles, 'retired': retired}
    assert set(windows) == {row['case'] for row in study['records']}
    summary['windows'] = windows
    summary['window_retired_sum'] = sum(row['retired'] for row in windows.values())
    summary['baseline_window_cycles_sum'] = sum(row['baseline_cycles'] for row in windows.values())
    for direction in DIRECTIONS:
        control = study['counts'][direction + '/full32']
        summary['direction'][direction] = {
            'conditional': control['conditional'], 'errors': control['raw_direction_errors'],
            'accuracy_percent': accuracy(control['conditional'] - control['raw_direction_errors'], control['conditional'])}
        for name in study['model_configs']:
            count = study['counts'][direction + '/' + name]
            reference = study['counts'][direction + ('/full64' if '64' in name else '/full32')]
            summary['target'][direction + '/' + name] = {
                **count,
                'initial_next_pc_accuracy_percent': accuracy(count['branches'] - count['initial_next_pc_errors'], count['branches']),
                'before_fetch_next_pc_accuracy_percent': accuracy(count['branches'] - count['before_fetch_next_pc_errors'], count['branches']),
                'before_EX_next_pc_accuracy_percent': accuracy(count['branches'] - count['before_EX_next_pc_errors'], count['branches']),
                'initial_taken_target_accuracy_percent': accuracy(count['initial_target_correct'], count['taken']),
                'initial_error_change_vs_same_capacity_full_percent': 100 * (count['initial_next_pc_errors'] / reference['initial_next_pc_errors'] - 1)}
    (DOCS / 'target-accuracy-summary.json').write_text(json.dumps(summary, indent=2) + '\n')

    base = study['counts']['TAGE_SC_Loop/full32']
    lines = [
        '# 四类目标获取方法：有限状态模型结果', '',
        '2026-10-02补测。18种目标组织×3种方向模型，共54组，使用预先划分的14个开发输入；没有运行train、验证/最终保留集，也没有改变稳定默认配置。', '',
        f"范围：5类代理负载各两个种子，加jsmn/miniz真实软件各冷/暖窗口。统计窗口共{base['branches']:,}条控制流、{base['conditional']:,}条条件分支、{base['taken']:,}次taken。计数加权汇总，冷/暖窗口有重叠，不是性能选型中的等家族平均。", '',
        f"基线观察窗口合计退休{summary['window_retired_sum']:,}条指令、{summary['baseline_window_cycles_sum']:,}周期。采样测试台设定700MHz、128KiB RAM、共享AXI的100ns首响应/10ns后续beat、无随机反压；不同于原生SoC/APB模型。这是既有开发小规模组，不是128请求长保留组；周期只说明采样规模，不是新候选的执行周期。", '',
        '## 预测准确率', '',
        '方向准确率只统计条件分支，在目标可用性门控之前计数。所有目标候选重放相同查询/解析时刻、共享同一方向模型及解析RAS4，因此目标组织不会改变这项隔离统计。', '',
        '| 方向模型 | 方向错误数 | 方向准确率 |',
        '| --- | ---: | ---: |']
    for direction, count in summary['direction'].items():
        lines.append(f"| {direction} | {count['errors']:,} | {count['accuracy_percent']:.3f}% |")
    lines += ['', '下表固定缩放TAGE＋SC＋Loop。下一条PC准确率覆盖条件分支、JAL、JALR/return；目标准确率只统计实际taken，缺项也计为不正确。`取指接受前`/`EX解析前`只使用严格早于该边界到达的预测，不等于已经实现局部恢复。', '',
              '| 目标组织 | 初始错误数 | 初始下一PC准确率 | 取指接受前准确率 | EX解析前准确率 | 初始taken目标准确率 |',
              '| --- | ---: | ---: | ---: | ---: | ---: |']
    for name in study['model_configs']:
        count = summary['target']['TAGE_SC_Loop/' + name]
        lines.append(f"| {name} | {count['initial_next_pc_errors']:,} | {count['initial_next_pc_accuracy_percent']:.3f}% | {count['before_fetch_next_pc_accuracy_percent']:.3f}% | {count['before_EX_next_pc_accuracy_percent']:.3f}% | {count['initial_taken_target_accuracy_percent']:.3f}% |")
    lines += ['', '方向与目标联合对照如下，单元格为初始下一PC错误数。这里的TAGE是本核缩放组织，不是作者大容量软件参考。不同目标方案不是只与旧BHT16/BTB16比较。', '',
              '| 目标组织 | BHT16 | TAGE | TAGE＋SC＋Loop |',
              '| --- | ---: | ---: | ---: |']
    for name in ('full16', 'full32', 'full64', 'predecode_direct', 'prefill_all', 'prefill_backward', 'compact32_U16'):
        values = [f"{study['counts'][direction + '/' + name]['initial_next_pc_errors']:,}" for direction in DIRECTIONS]
        lines.append('| ' + name + ' | ' + ' | '.join(values) + ' |')
    lines += ['', '## 结构、时机与成本', '',
              '`full16`是原16项/2路、线性索引、轮转替换、所有控制流准入；`full32/full64`是4路、折叠索引、SRRIP、仅新条件taken准入。所有模型保留完整PC身份。容量收益与算法收益分开看。', '',
              '- `predecode_type/direct`：只有实际完整安装、仍驻留I$的指令可提供类型；direct还提供B/J立即数，通过PC加法取得目标，return可使用已有RAS。不在回填结束前提供未到达的指令，也不预知分支结果。假设元数据查询和直接目标在原预测期限内完成，尚需RTL/STA检验。',
              '- `prefill_all/backward`：完整行安装后，根据该行真实指令生成B/J提示；后者只选后向条件分支及JAL。队列四项、溢出丢弃、每拍最多一次空闲写入，EX训练优先；不覆盖已驻留条目，不训练方向或RAS。完整行译码与队列的实现成本不能遗漏。',
              '- `tier4_32_L1/L2/L3`：快表4项/2路轮转，慢表32项/4路；慢表查找时快照在1/2/3拍后提供覆盖结果，总容量36项。只诊断预测到达时机，未重建候选错误路径、请求取消和端口竞争。',
              '- `region*_r2/r4`：每条目标保存低16位和2/4项区域索引，区域表保存高16位。区域被替换时先清除全部引用，禁止旧索引拼出错误地址。默认假定并行选择在预测期限内完成；`L2`独立展示两拍依赖读取的影响。',
              '- `compact*_U16/mixed`：目标分别按统一16位或每路12/16/24/32位保存，借查询PC高位重建。写入先检查可表达范围，必要时迁移宽路；无法表达就失效/拒绝，不截断。分别与相同32/64项完整目标对照，三种方向都已组合。', '',
              '以下仅为逻辑存储位数，不是综合面积。额外读取端口、PC标签访问、加法/译码/仲裁、流水与在途身份状态另计；不据此判断700MHz或面积×时间。', '',
              '| 组织 | 主BTB位数 | 额外快表位数 | 指令metadata位数 | 提示队列位数 |',
              '| --- | ---: | ---: | ---: | ---: |']
    for name in ('full16', 'full32', 'full64', 'predecode_type', 'predecode_direct', 'prefill_all', 'tier4_32_L2',
                 'region32_r2', 'region32_r4', 'region64_r4', 'compact32_U16', 'compact32_mixed', 'compact64_U16', 'compact64_mixed'):
        count = summary['resources'][name]
        lines.append(f"| {name} | {count['target_table_bits']:,} | {count['fast_table_bits']:,} | {count['instruction_metadata_bits']:,} | {count['prefill_queue_bits']:,} |")
    lines += ['', 'type旁带为256槽×3位；direct为256槽×(3位类型＋21位位移)。预填充按完整行预译码来源保守计同样6144位；若改成逐beat译码/暂存，需要重新定义时机。独立查询I$身份若复制32条tag/valid，另需约800位；使用现有tag也需要满足读端口/路径约束，不能当成零成本。队列按4×66位＋7位指针/计数计算。', '',
              '## 结论与适用范围', '',
              '- 预译码＋直接目标相对同方向full32减少19.066%的初始下一PC错误，值得进入RTL候选。它引入的旁带远大于单纯类型信息，仍不能判断净面积/频率收益；jsmn冷窗错误反而增加2.700%。拿到目标会让原本被BTB缺项掩盖的错误taken方向生效，目标更准不保证每项输入都更好。',
              '- 全B/J预填充错误增加12.389%；仅后向分支/JAL也增加4.601%。前者14个输入均退化；后者部分输入改善，但runtime_graph最差增加11.801%。当前提示准入/替换造成额外污染，不能因为发得早就判定有益。write_attempts包含命中后忽略的尝试，不是实际新条目数。',
              '- 快4＋慢32在二拍慢预测下，取指接受前只有82.663%准确率，EX前可达91.823%；原单表full32初始已有91.826%。晚命中不能直接当成已消除EX恢复的周期，分级方案需要时序与恢复硬件的实际收益证明。',
              '- 区域表和U16保持相同容量完整目标的准确率。区域表32项/4区域使BTB及区域表合计逻辑位数减少18.457%，U16使BTB位数减少25%；这不是整核面积降幅。当前输入没有区域表替换和U16范围拒绝，不构成跨区压力验证。异构窄路产生受限放置，32项错误增加0.365%，64项增加0.209%。',
              '- 压缩64项的准确率改善主要来自容量；3008位仍高于完整32项的2048位，不能称作同预算翻倍。缩放SC＋Loop在这组固定事件上比纯TAGE方向错误多3201次，本轮没有调整它来迎合结果。', '',
              '## 核验与复现', '',
              f"新加的旁观记录不驱动DUT。14个输入的RESULT/COUNTERS/DETAIL与原基线逐行一致；{summary['baseline_query_checks']:,}次真实查询逐次核对BTB命中/目标/类型与BHT状态，全部一致。每条退休指令与冻结镜像核对，B/J目标独立由指令编码计算并与解析结果核对。", '',
              '模型只在实际解析时训练，使用完整自然前缀；Q/F读取沿前状态，I$安装和提示写入在沿后生效。记录来源为实际I$的L(安装/失效)、D(回填word)、V(维护失效)事件。没有把反汇编全程序当成提前可用的目标表。', '',
              '定向测试覆盖位移符号、跨区迁移/拒绝、区域索引复用、完整安装前不可见、四项队列与训练优先。它们验证模型协议；本轮软件没有FENCE.I，因此不声称新机制的整核恢复/总线错误/安全/DiffTest已完成。既有RTL与默认配置未改。', '',
              '重放命令和旁观记录重建见[入口](README.md#四类目标方法的准确率重放)。逐输入计数、配置及来源哈希见[target-accuracy-models.json](target-accuracy-models.json)，比例与资源口径见[target-accuracy-summary.json](target-accuracy-summary.json)；本页由`summarize_target_accuracy.py`生成。原有保留集PPA/性能结果仍以`final-results.json`为准，不能与本页模型结果混用。', '',
              '固定事件模型不生成候选自己的错误路径、训练时刻和I$驻留变化；预译码查询、区域拼接、TAGE输出的延迟只按声明处理。当前结论限于候选准确率筛选，不是新RTL已能运行、700MHz已通过或CPU已加速。', '']
    (DOCS / 'target-model-study.md').write_text('\n'.join(lines))
    print('SUMMARIZED', summary['inputs'], 'inputs and', summary['joint_configurations'], 'configurations')


if __name__ == '__main__':
    main()
