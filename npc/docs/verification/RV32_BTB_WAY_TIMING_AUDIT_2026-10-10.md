# RV32：BHT/BTB多路选择与STA核查

检查 `ysyx-workbench-rv32-interview` 的 `316d1d2`，默认 rv32-balanced，未修改RTL。
现有子模块用户修改保留；replay无预测实验不属于本次时序对象。
按当前源码重新综合，NanGate45 AREA3、820MHz映射、相同复位缓冲和SDC；面积102004.882 µm²。
复测同一网表700/715/720MHz，四类时序全部检查；属于综合后STA，不是布局布线签核。

## 电路结论

BHT不是组相联结构：默认16项两位计数器按PC直接索引，没有way循环或逐路tag比较。
BTB查询侧各way独立比较tag，one-hot命中按位合并target/kind；for循环不表示时钟循环，
按位OR是关联归约，不等同于逐路更新最大值的串联比较/选择依赖。
实际查询深度还包括set选择、tag比较、方向/目标选择，最终以映射路径为准。

BTB训练侧存在两个可扩展性问题：

- policy2/4的victim选择逐路比较当前RRPV和累计maximum_reuse，有跨迭代依赖。
- 命中/首个空路选择使用累计training_hit_present/empty_way_present，包含优先级依赖。

当前默认BTB16/2路/policy0，只保留后者的两路优先级，不生成RRIP最大值链。
compact BTB另有fit/首空/轮转候选的优先级选择，当前target-way-bits=0不实例化。
I-cache默认4路/policy13的查询victim已用并行比较；8路及以上的fallback仍有编码再索引依赖，
不能把现有2/4路改写声称为任意路数都不存在依赖链。

## 本次实测

| 整核频率 | 最差data setup slack | 结果 |
| --- | ---: | --- |
| 700MHz | +0.025 ns | 四类检查通过 |
| 715MHz | +0.001 ns | 四类检查通过 |
| 720MHz | −0.008 ns | setup失败 |

全核最差路径从instruction AXI响应输入，经I-cache返回/反压、IFU指令/预测处理和PC更新，
到 `u_core.u_ifu.predictor_fetch_pc_q_9__reg_p:D`。当前最差报告路径没有经过BTB或BHT实例。
这不代表表路径不存在，因此另做endpoint-filtered报告：

| 700MHz筛选范围 | 目标D pin数 | 最差setup slack |
| --- | ---: | ---: |
| BTB写入寄存器 | 1000 | +0.373 ns |
| BHT计数器更新 | 32 | +0.868 ns |
| 预测响应寄存器 | 69 | +0.187 ns |

后者包括查询地址、BTB/BHT/RAS选择和预测响应生成，并非BTB单模块延迟。
过滤报告用于路径归因，不可用其中Freq字段宣称整核频率。
上述余量证明当前默认两路BTB训练选择不是700MHz瓶颈；仍不能据此认证8路/16路扩展。

## 历史候选的边界

16项/4路/policy2的旧候选曾在740MHz通过，最差setup +0.005ns、终点在I-cache victim寄存器。
128项/2路/policy0旧候选在520MHz通过，最差setup +0.010ns、终点在BTB entry寄存器。
后者增加的是组/表项，way仍为2；不能将其退化归因于way比较链。
这些是有原始版本绑定的历史候选，不是本次将当前核改为四路/128项的新测量。
其比较同时有策略与整核映射差别，不能用频率差单独归因于某一循环。

## 建议

扩展BTB way之前重写训练选路：独立生成hit/empty向量，再优先编码；RRIP仅2bit，
可各路并行判定RRPV=3/2/1并归约最高等级，再用低路号优先独热选路。
这避免逐路累计maximum和编码way后二次索引，不需要新寄存级。
须保持原victim平局优先、空路/命中优先、失效及训练同拍语义，先做独立模型等价再做STA/面积。
本次未实现该原型，不能声称它已经提频或降低面积。当前默认频率仍700MHz。

## 证据与复现

`data/btb-way-audit-20261010/audit.json`包含版本、源码、配置和网表哈希，以及实测结果。
700/715/720的完整报告以gzip保存；训练与响应三个范围另有rpt.gz、Tcl、目标pin列表。
归档原始mapped netlist压缩件、综合stat、约束及复位连通性检查；清理本次大临时目录。
Tcl中的scratch绝对路径为运行时路径，复现时修改RESULT_DIR/netlist/SDC路径并设置CLK_FREQ_MHZ=700。
重新综合入口：

```bash
NPC_HOME="$PWD/npc" python3 npc/scripts/run_synthesis.py --target sta-reset --keep-artifacts \
  --output npc/result/synthesis/btb-audit/current NPC_CONFIG=rv32-balanced \
  STA_FREQUENCY_MHZ=820 'STA_SYNTH_STRATEGY=AREA 3' \
  STA_TOOL_DIR="$PWD/npc/result/sta/rv32-interrupt-20260906/toolflow"
```

不重映射的指定频点检查使用同一netlist/SDC及toolflow/scripts/sta.tcl，
环境CLK_FREQ_MHZ设为700、715或720；不要把820映射目标当作合法运行频率。
本次无RTL改动，未运行软件性能或功能回归，不声称有周期收益，也没有提交或推送。
