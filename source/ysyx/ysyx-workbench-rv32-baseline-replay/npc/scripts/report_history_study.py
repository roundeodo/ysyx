#!/usr/bin/env python3
"""Publish compact measurements and an evidence index after the study audit passes."""
import argparse
import json
from pathlib import Path
import shutil
from explore_frontend import NPC,sha
from buffer_history_training import PARENTS


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--root',type=Path,required=True)
    a=p.parse_args();root=a.root.resolve()
    audit=json.loads((root/'audit.json').read_text());assert audit['status']=='passed'
    data=json.loads((root/'comparison.json').read_text());freeze=data['freeze']
    out=NPC/'docs/verification/data/branch-history-20260924';out.mkdir(parents=True,exist_ok=True)
    files=['comparison.json','selection-freeze.json','timing-audit.json','audit.json','model.json',
           'history-model.json','history-model-correction.json','model-parity.json','configurations.json',
           'infrastructure-parity.json','first-qualified-pair.json','execution-sources.json',
           'tool-bindings.json','comparison-audit.json','family-diagnostic-700.json',
           'buffer-controls-plan.json','training-buffer-noop.json','practical-common-frequency.json','artifact-compaction.json','completion-runner-changes.json']
    for name in files:
        if (root/name).exists():shutil.copy2(root/name,out/name)
    shutil.copy2(root/'correlation-diagnostic/results.json',out/'correlation-diagnostic.json')
    for name in PARENTS:
        shutil.copy2(root/'ppa'/name/'buffer-repair.json',out/f'buffer-repair-{name}.json')
    (out/'references.json').write_text(json.dumps(json.loads((root/'references/manifest.json').read_text()) if (root/'references/manifest.json').exists() else {'references':'See BRANCH_RESEARCH_NOTES.md'},indent=2)+'\n')
    logs=sorted([*root.rglob('*.log'), *root.rglob('*.log.gz')])
    index=[{'path':str(p.relative_to(root)),'bytes':p.stat().st_size,'sha256':sha(p)} for p in logs if p.name not in ['completion.log','report-export.log','finalization.log']]
    (root/'log-index.json').write_text(json.dumps(index,indent=2)+'\n');shutil.copy2(root/'log-index.json',out/'log-index.json')
    lines=['# 分支历史实验的最终比较','',
           f'共同合法频点：{freeze["common_mhz"]} MHz；独立物理访存模型首响应100 ns、后续beat10 ns。',
           '面积为NanGate45映射单元面积，频率为布局前完整STA通过点，网格20 MHz。',
           '','| 配置 | 面积 μm² | 合法 MHz | 同频时间变化 | 各自频点时间变化 | 开发面积×时间变化 |',
           '| --- | ---: | ---: | ---: | ---: | ---: |']
    for name,ppa in freeze['ppa'].items():
        own=freeze['development'][name];common=data['common_development'][name]
        lines.append(f'| {name} | {ppa["area_um2"]:.3f} | {ppa["mhz"]} | {(common["time_ratio_gm"]-1)*100:+.3f}% | {(own["time_ratio_gm"]-1)*100:+.3f}% | {(own["area_time_ratio_gm"]-1)*100:+.3f}% |')
    practical=json.loads((root/'practical-common-frequency.json').read_text())
    lines += ['',f'全矩阵同频点被原始G512映射限制为{freeze["common_mhz"]} MHz，并不表示基线只有这个频率。另将决赛候选在实际可用的{practical["mhz"]} MHz下比较；以下仅为开发诊断，不改变已经冻结的选择。',
              '', f'| 同为{practical["mhz"]} MHz | 时间变化 | 面积×时间变化 |', '| --- | ---: | ---: |']
    for name,x in practical['development'].items():
        lines.append(f'| {name} | {(x["time_ratio_gm"]-1)*100:+.3f}% | {(x["area_time_ratio_gm"]-1)*100:+.3f}% |')
    resources={}
    traffic={}
    label='dev-common' if freeze['common_mhz']==720 else f'dev-common-{freeze["common_mhz"]}'
    for name,ppa in freeze['ppa'].items():
        cells=json.loads((root/'ppa'/name/'cells.json').read_text())
        timing=json.loads((root/'ppa'/name/'timing.json').read_text())[str(ppa['mhz'])]
        resources[name]={'dff':cells['dff'],'data_latches':cells['data_latches'],
                         'clock_gates':cells['clock_gates'],'critical_groups':timing['groups']}
        rows=json.loads((root/'rtl'/label/name/'results.json').read_text())['results']
        traffic[name]={key:sum(x['counters'][key] for x in rows)
                       for key in ['queries','i_bursts','i_beats','d_beats','btb_missing','direction','target']}
    (out/'resources.json').write_text(json.dumps(resources,indent=2)+'\n')
    (out/'traffic.json').write_text(json.dumps(traffic,indent=2)+'\n')
    lines += ['','| 配置 | 预测查询 | I总线beat | D总线beat | BTB无匹配纠正 | 已有目标方向纠正 |',
              '| --- | ---: | ---: | ---: | ---: | ---: |']
    for name,t in traffic.items():
        lines.append(f'| {name} | {t["queries"]} | {t["i_beats"]} | {t["d_beats"]} | {t["btb_missing"]} | {t["direction"]} |')
    lines += ['','上表是共同合法频点下十个开发输入的事件数之和，未按家族加权；访问量不是功耗测量，同一次预测查询在不同策略中可能访问不同数量的表。',
              '新增触发器、门控单元和关键路径端点见`resources.json`，不能把表的逻辑位数等同于整核面积。']
    lines += ['',f'开发选择：{freeze["selected_development"]}；简单对照：{freeze["simple_comparator"]}；TAGE对照：{freeze["tage_comparator"]}。',
              f'保留输入核验后的建议：**{data["recommendation"]}**。默认参数未自动修改。',
              'B0I使用新源码但关闭TAGE；其与B0的映射差别应单列，不算作预测算法收益。',
              'F后缀表示仅对大扇出的BHT训练数据网增加BUF_X4缓冲树：触发阈值64个负载，树内扇出不超过16。RTL、预测策略和周期数不变；面积与STA重新测量。所有原有单元连接的结构等价检查通过。该收益属于电气驱动修复，不属于新预测算法。',
              '','| 保留配置 | 各自频点时间变化 | 面积×时间变化 | 最差单项时间变化 |',
              '| --- | ---: | ---: | ---: |']
    for name,x in data['held_own_frequency'].items():
        lines.append(f'| {name} | {(x["time_ratio_gm"]-1)*100:+.3f}% | {(x["area_time_ratio_gm"]-1)*100:+.3f}% | {(x["worst_time_ratio"]-1)*100:+.3f}% |')
    lines += ['','20 ns、200 ns首响应和随机反压结果详见`comparison.json`的`sensitivity`。',
              '开发为五类软件的新输入；保留为六类新输入，包含未参与开发的NMS。程序家族并非全部首次出现。',
              '没有完整AI模型推理或功耗测量，不将方向错误次数换算成固定罚时，也不把合成诊断加入选型分数。',
              '','## MicroBench参照','',
              '| 配置 | MHz | Total秒 / IPC | Scored秒 / IPC |','| --- | ---: | --- | --- |']
    for name in ['B0I','T16']:
        path=root/'microbench'/name/'report.json';m=json.loads(path.read_text())
        lines.append(f'| {name} | {m["cpu_mhz"]} | {m["total"]["timer_seconds"]:.6f} / {m["total"]["ipc"]:.6f} | {m["scored"]["timer_seconds"]:.6f} / {m["scored"]["ipc"]:.6f} |')
        shutil.copy2(path,out/f'microbench-{name}.json')
    lines += ['','这里只重跑test，原生计时器与被动计数窗口一致；观察器开／关验证通过。没有重跑train。',
              'MicroBench使用原生ysyxSoC延迟换算模型，设备参考100 MHz；它与上面的100 ns／10 ns独立存储模型不同。原生delayer仍有提前VALID影响换算等待的已知局限，因此这些秒数是该仿真环境内的参照，不是硅上测量或选型主分数。详见[计时规则](../../MICROBENCH_TIMING_RULES.md)。',
              '','## 证据和复现','',
              '恢复协议的诊断模型曾存在不公平比较，已修正并保留作废记录；见`history-model-correction.json`。',
              '当前模型的推测历史与完美前缀历史误差相等，由完美分支身份、正确路径回放和解析前丢弃年轻查询这些假设决定，不能当成真实CPU已达到理想预测的证据。',
              '','```sh',f'python3 npc/scripts/reproduce_history_study.py --root {root.relative_to(NPC.parent)} --check-only',
              f'python3 npc/scripts/reproduce_history_study.py --root {root.relative_to(NPC.parent)} --output npc/result/branch-history-reproduction','```',
              '',f'原始目录：`{root}`。`log-index.json`列出日志路径、大小和哈希；RTL和软件镜像保留在冻结快照中。',
              '已压缩的原始日志以.log.gz保留；可用gzip -cd读取。artifact-compaction.json记录压缩前哈希及重复STA网表对应的保留文件。',
              '源代码哈希见`execution-sources.json`，工具与标准单元库哈希见`tool-bindings.json`。没有推送、合并或改变远程分支。','']
    (out/'README.md').write_text('\n'.join(lines))
    print('PASS compact report',out,flush=True)

if __name__=='__main__':main()
