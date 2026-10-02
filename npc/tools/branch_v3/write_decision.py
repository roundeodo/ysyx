#!/usr/bin/env python3
"""Produce the human-readable decision from the sealed final results."""
import json

from run_btb_matrix import NPC


def main():
    docs = NPC/'docs/research/branch-v3'
    final = json.loads((docs/'final-results.json').read_text())
    rows = {row['ppa']: row for row in final['results']}
    labels = {'BT0': 'BHT16＋原BTB16',
              'H2E-victim': '弱态静态/动态混合＋早期直接目标',
              'BT32-select-fold': 'BHT16＋改进BTB32',
              'NSL-BT32-fold': '缩放TAGE＋SC＋Loop＋改进BTB32',
              'NSL-BT64': '缩放TAGE＋SC＋Loop＋改进BTB64'}
    lines = ['# 分支预测 V3：本轮取舍', '',
             '目标供给的改进有效。均衡选择仍是小型混合方向预测加早期直接目标；'
             '更大的BTB和TAGE/SC/Loop提供更低延迟，但在当前核上面积增长更大。', '',
             '本轮没有改变稳定默认配置，没有推送或合并。新增索引、准入和其他实验机制均由显式开关选择。', '',
             '## 冻结后的保留结果', '',
             '下表只使用冻结后的新输入。固定RV32I顺序单发射、I$1KiB/4路/32B/策略13、'
             'D$256B/2路/16B，最终五个候选均为2MiB测试台RAM。',
             '短组为六类代理及jsmn/miniz，共16个输入窗口；长组为128个不同词表请求的两类软件，'
             '冷/暖共4窗。家族等权、家族内输入等权，配对时间比取几何平均。两组分开报告。', '',
             '| 配置 | 全核面积 μm² | STA通过 MHz | 同频400MHz短组时间减少 | 各自频点短组时间减少 | 各自频点长组时间减少 |',
             '| --- | ---: | ---: | ---: | ---: | ---: |']
    for name in labels:
        if name not in rows:
            continue
        row = rows[name]
        gains = [100*(1-row[key]['paired_geomean']) for key in
                 ['short_common_400', 'short_own', 'long_own']]
        lines.append(f'| {labels[name]} | {row["area_um2"]:,.0f} | {row["mhz"]} | '
                     + ' | '.join(f'{gain:.2f}%' for gain in gains)+' |')
    lines += ['', 'STA为相同NanGate45标准单元、AREA3、820MHz映射后的setup/hold/clock-gating检查，'
              '细扫间隔5MHz。没有布局布线签核。改变CPU频率后重新运行固定100ns/10ns存储服务，'
              '没有直接沿用旧周期数除以新频率。',
              '交付核验覆盖最终五种配置的56份综合输入RTL。早期H2E映射使用的源码早于默认关闭的BTB开关；'
              '按原流程重新映射交付源码后，网表、SDC、面积及700MHz时序结果完全相同，'
              '没有改变冻结参数或频点。详见[交付PPA核验](ppa-delivery-audit.json)。', '',
              '## 三种选择', '',
              '- 最低成本：稳定基线。更便宜的taken-only准入在验证输入上慢3.77%，已在保留集前否决。',
              '- 面积×时间：弱态混合＋早期直接目标。counter为弱态时用BTFNT，强态时用BHT；'
              'I-cache返回B/J指令后计算直接目标，在EX前纠错。未增加流水级。',
              '- 面积增加10%或20%以内的低延迟：BTB32/4路/fold/SRRIP/taken，方向仍为BHT16。'
              '增加5%以内仍选混合＋早期目标。',
              '- 不限制面积的低延迟：本轮冻结候选中为NSL＋BTB64；该点超出上述预算档，作为可运行原型保留。', '']
    balanced = rows[final['proposal']]
    lines += [f'均衡候选面积增加{100*(balanced["area_ratio"]-1):.2f}%，面积×时间在短/长保留组分别减少'
              f'{100*(1-balanced["short_area_time_ratio"]):.2f}%/{100*(1-balanced["long_area_time_ratio"]):.2f}%。'
              f'其最差短/长输入时间比为{balanced["short_own"]["worst_ratio"]:.4f}/'
              f'{balanced["long_own"]["worst_ratio"]:.4f}，均符合3%门槛。',
              '改进BTB32面积约增加9.17%，面积×时间仍增加约6%；NSL/BTB64面积约增加41.34%，'
              '面积×时间增加约35%～36%。低延迟收益没有抵消它们的面积增长。', '',
              '## 为什么这样选', '',
              '1. 先区分方向是否正确、目标是否可用、结果是否及时。原BTB16限制TAGE收益；'
              '改善目标后，本轮开发同频收益从单独TAGE的0.43%增加到TAGE/BTB64的5.07%。',
              '2. 容量、索引、替换、准入分开对照，再与方向预测组合。模型120点，BTB追加闭环RTL/PPA35点，'
              '另保留此前强简单对照；没有将所有开关一起开启后只比较旧基线。',
              '3. 单看错误次数会误判。相同730MHz的量化加载反例中，准入优化减少纠错，却使I-cache miss'
              '从833增至1,390，程序慢3.77%。8KiB I-cache诊断也反转了gshare与TAGE的排序；主线缓存未改。',
              '4. 合法频率不能省略。BHT256/BTB32在700MHz逻辑比较更快，但当前更新路径只能通过420MHz，'
              '合法频点反而更慢。NSL/BTB32实际通过720MHz，不能再用“SC/Loop一定跑不到700MHz”排除它。',
              '5. 长组四个基线窗口累计约82%的周期被观察器优先归为数据等待。该分类不是可直接消除的因果损失，'
              '但解释了仅提高方向准确率难以带来同等比例整核加速。', '',
              '## 验证与学习入口', '',
              '39组BTB配置做了140.4万次查询、3,110.4万个表项状态比对；五种故意错误被检出。'
              'BTB扩展与当前简单混合共100项NEMU比较、40项安全目标通过。新NSL/BTB32整核还有'
              '313,117个真实事件的模型/RTL状态检查，并验证观察器不改变周期和输出。',
              '20/100/200ns首响应、随机反压两seed、两种整体代码偏移均另有结果。原生SoC MicroBench只跑test，'
              '同700MHz计分IPC为0.400584→0.413593（BTB32）→0.420128（NSL/BTB32）；没有运行train。', '',
              '研究来源与裁剪见[literature.md](literature.md)，电路见[BRANCH_V3_DESIGN.md]'
              '(../../microarchitecture/BRANCH_V3_DESIGN.md)，主效应/失败原因见[btb-study.md](btb-study.md)。'
              '机器结果为`btb-results.json`、`final-results.json`；冻结为`selection-freeze.json`；'
              '原始路径与哈希为`evidence-index.json`；学习窗口为`learning-curves.csv/json`。', '',
              '本轮没有实现全部论文方案。分级BTB、行预译码预填充、完整ITTAGE仍停留在机会/模型诊断；'
              '推测RAS和原作者完整SC特征尚未实现；作者标准竞赛轨迹复跑及支持多个在途预测的延迟训练适配'
              '尚未完成，详见`coverage.json`。'
              '当前结论针对已测组织、固定软件和存储服务，不代表分支预测研究没有其他更好方法。', '']
    (docs/'decision.md').write_text('\n'.join(lines))
    print('WROTE', docs/'decision.md')


if __name__ == '__main__':
    main()
