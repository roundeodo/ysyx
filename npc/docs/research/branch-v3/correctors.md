# SC 与 Loop 为什么增加了错误

当前实现是独立缩放原型，不是作者完整TAGE-SC-L的等价移植。
对十四个开发窗口、578,760次条件分支，实际RTL方向错误为：

| 配置 | 方向错误 |
| --- | ---: |
| TAGE | 25,981 |
| TAGE＋Loop | 26,102 |
| TAGE＋SC | 29,129 |
| TAGE＋SC＋Loop | 29,225 |

这里固定默认几何、解析历史、early target/RAS关闭；不是模型立即训练的错误率。

## 已定位的直接原因

从每次查询保存的TAGE方向、SC和及最终方向，结合真实解析更新重放选择状态，
四配置共核对12,637,366次RTL查询，包括错误路径查询；每项最终方向必须完全一致。
各配置按实际条件分支顺序对齐。完整逐状态正确性仍由另列cosimulation承担。

在组合配置本身，SC将1,690次错误改对，却将4,829次正确改错，净增加3,139次错误。
Loop在SC之后将152次错误改对、352次正确改错，净增加200次。
组合内部的TAGE方向有25,886次错误，所以：

`25,886 + 4,829 - 1,690 + 352 - 152 = 29,225`。

它与单独TAGE的25,981次并非完全相同：预测改变错误路径与查询/训练时刻。
因此相对独立TAGE的3,244次增量不能全部硬分给SC某一个模块。

SC损害主要发生在非弱tagged provider上：改对342次、改错3,105次。
弱tagged provider上则改对347次、改错185次；base来源改对1,001次、改错1,539次。
这些类别取查询快照的provider及weak位，“非弱”不冒称已实现作者的HighConf分类。

当前SC把TAGE方向只作为固定±4先验，覆盖条件仅为SC总和达到全局阈值，
没有结合provider置信度学习何时允许覆盖。阈值只有1～31；64.73%的条件查询中已经达到31，
而总和幅度可到97。这说明全局门限已经经常受上限约束，但不能单凭这一点断言放宽上限必然更好。

结构上还有三张各16项、无身份tag的小权重表及有限全局历史特征，容易混合不同分支的统计。
“特征不足/别名干扰各占多少”尚未有独立因果实验；当前确证的是错误覆盖的次数和发生位置。

## 与作者实现的差别

[作者论文](https://jilp.org/cbp2016/paper/AndreSeznecLimited.pdf)第4、5节，
以及冻结的`references/AndreSeznecLimited/cbp8KB/predictor.h`说明：
SC还利用预测置信度、局部等历史，选择器结合TAGE置信度和SC和幅度；
源码有`HighConf/MedConf`、`FirstH/SecondH`、PC索引阈值与Loop有用性选择器`WITHLOOP`。
这些与本原型的一个全局阈值、固定先验和四项直接映射Loop不同。
论文方案的预算和轨迹也不同，不能用这些差别直接推算本核应有多少收益。

模型对照也必须分开：此前十个代理、立即训练、ROI冷启动的M0中，
SC净增加1,516次错误，Loop净减少96次；真实RTL中Loop也会增加错误。

TAGE＋Loop消融的真实时机检查发现：6,212次Loop有效查询中，1,034次在自身解析前
current已经被较老迭代更新，而PC、trip、direction、confidence仍相同。
其中388次查询方向错误，如果只换成解析前已更新的current就会正确；反方向变化为0次。
这388次不是“Loop改错次数”的子计数：也包含TAGE本身同样错误、Loop未改变方向的情况，不能与348相加。
其中ini两个输入各162次，quant_loader一个输入64次，说明迭代位置在查询时落后确实发生。

解析时的current不能直接用于更早的预测。后续要验证带恢复的推测迭代计数，或在迭代位置不可靠时
禁止Loop覆盖；不能把这里的诊断当作已实现修复或节省388次固定惩罚。
证据见[loop-timing-attribution.json](loop-timing-attribution.json)。复现命令：

`python3 npc/tools/branch_v3/analyze_correctors.py --configurations TAGE_Loop --output npc/docs/research/branch-v3/loop-timing-attribution.json`

## 下一步的验收顺序

先分别验证置信度选择、SC阈值与Loop迭代时机；每项用原组织作消融，
再考察增加特征或容量。新规则不能只在立即训练模型成立，还须实际查询/更新重放、RTL与PPA。
扩大目标软件输入、自然执行阶段和暖窗口后再判断稳定性；不运行train、不使用最终保留集选参。
当前没有修改预测算法或把该组合设为默认，也不能据这个原型的负结果否决完整TAGE-SC-L。

复现：`python3 npc/tools/branch_v3/analyze_correctors.py`。
机器结果：[corrector-attribution.json](corrector-attribution.json)。记录逐输入计数、每个分支PC、
阈值分布、provider类别、二进制及解压事件哈希。
