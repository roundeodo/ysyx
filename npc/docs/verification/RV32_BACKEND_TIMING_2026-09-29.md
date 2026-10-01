# RV32 ROB 后端时序修复

后续显式 Issue 级已替代本文的强制 fetch buffer 落拍，当前实现见 [Issue 实施记录](RV32_ISSUE_2026-09-29.md)。本文数据保留为历史对照。

2026-09-29。保留“已有 fetch buffer 寄存输出 + DIV 先写 ROB 再退休”，4 项 ROB/load overlap
配置从 600 MHz 提升到 **700 MHz**，面积从 120647.758 降到 **119769.692 μm²**。
没有新增独立 issue 级，没有修改综合策略或放松时序约束。ROB 仍须显式开启。
当前电路只在[后端说明](../microarchitecture/BACKEND_DESIGN.md)维护，本文记录测量与取舍。

## 比较基线与问题定位

基础提交 `5493a6aec976f4f9bdc075834d3f1202b0ae16ef`。比较对象是本轮开始前**已实现 ROB 的工作区快照**，
不是把原提交误称为已含 ROB。原始源码位于 `npc/result/backend-rob/ppa/retained4/source/`；
本轮修改前文件位于 `npc/result/backend-timing-20260929/baseline-source/`。原有 1202 项 result 删除未改动。
配置、工具、镜像与源码指纹见[配置记录](data/rv32-backend-timing-2026-09-29/configurations.json)。

原关键路径：AXI RVALID → I-cache 回填响应/early restart → 空 fetch buffer 直通 → 译码 →
最近生产者及源就绪判断 → ID/EX/ROB 分配。ready 反馈还会延伸到 I-cache RRIP 的门控使能。
700 MHz 原网表 data/gating setup 为 −160/−169 ps。因此首先检查逻辑深度与真正的寄存边界。

## 候选与实际保留的电路

| 候选 | 全部 STA 组通过的 MHz | 面积 μm² |
| --- | ---: | ---: |
| 原 ROB4 | 600 | 120,647.758 |
| 并行 scoreboard | 580 | 120,034.362 |
| 并行 scoreboard + 取指寄存 | 540 | 119,385.322 |
| 仅取指寄存 | 640 | 119,774.214 |
| 仅 DIV 经 ROB 退休 | 640 | 120,611.848 |
| 取指寄存 + DIV 经 ROB 退休 | 700 | 119,769.692 |
| 当前 ROB 关闭 | 680 | 116,993.982 |

1. **并行 scoreboard，拒绝**：并行匹配后屏蔽更老的同名写者，用唯一选择向量取数据与就绪。
   2/4/8 项随机参考检查通过，但实际映射仅 580 MHz；与取指寄存组合只有 540 MHz。
   无寄存器增加并不保证门级路径更短，最终恢复原年龄选择实现。未声称其性能已经跑过完整程序。
2. **复用 fetch buffer，保留**：ROB 配置将 `BYPASS_ENABLE` 置零；已有两项数组成为真实寄存边界。
   空队列首条交付增加一拍，连续输出仍可每拍一条，满队列同时出入不变；没有新增指令搬移级。
   满队列 ready 仍组合反馈，没有宣称彻底切断所有反压路径。ROB 关闭时继续使用原直通。
3. **DIV 结果经 ROB 退休，保留**：独立除法器的迭代状态已寄存，但最终符号修正和快捷判断仍是组合逻辑。
   先写已有 ROB 结果存储，避免经退休选择进入 GPR/访存副作用授权的长链；不增加除法结果寄存器。
   位于队首时至多多等一个退休拍；完成当拍数据前递、除法快捷路径、老结果交付与新上下文接收均保留。

取指寄存或 DIV 退休调整单独均为 640 MHz，组合为 700 MHz，不能把收益只归给其中一项。
未增加通用 issue 寄存级：复用现有边界已经达到目标，而剩余最长路径位于 EX/LSU，
在它之前再加一个 issue 级不会切断这条路径。该更深流水方案没有实现，也不虚构其 PPA。

## 时序边界

沿用 NanGate45、`AREA 3`、820 MHz 映射目标、同一 reset boundary 与 SDC；20 MHz 网格检查
数据 setup/hold 和时钟门控 setup/hold 全部组。700 MHz 无违例，报告的四项最差裕量依次为
**0/+60/+20/+97 ps**。data setup 按报告精度四舍五入为 0，说明余量很小。
720 MHz data/gating setup 为 **−32/−20 ps**，未通过；不能宣传已经达到 720 MHz。

现在最差数据路径为 ID/EX 操作数 → 有效地址加法 → 访问检查/LSU → 数据路由 → uncached AXI WVALID；
另一条限制路径仍到 I-cache RRIP 门控使能。继续提频应针对这些路径单独评估，不凭“增加一级”保证频率。
这些是综合后理想时钟、未布线的估计，不能等同于硅上或布局布线后的 700 MHz 保证。
稳定 ROB 关闭配置独立重综合仍为 116993.982 μm² / 680 MHz，且新旧映射网表 SHA256 完全一致。
未沿用旧提交的 700 MHz 数字。

## 周期代价与实际执行时间

以下均为 MicroBench **test**。同一 RV32IM 镜像 SHA256：`628d93c7fc6df6804d690769a8f5fe02782099f1292bd7abda23f61702c611ad`。
CPU 每个频率重新构建 `device-clock-v1` 延迟模型；设备 100 MHz，原生计时器 1 MHz。
IPC 用同一原生计时窗口内的退休数/周期数，程序未插入统计 CSR 读取。
新旧仿真清单核验：工具、镜像和延迟模型相同，参与构建的源码仅变化 fetch buffer、core、backend 三个 RTL 文件。
Scored 是多个子窗口之和，其 tick 量化误差也累加；它与 Total 并非同一个统计窗口。
Total 含校验、输出和轮询，因此即使软件镜像相同，退休数仍可能随时序改变。

| 配置 | MHz | Total 周期 | Total IPC | Total 原生 ms | Scored 原生 ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| 原 ROB4 | 600 | 2006450 | 0.240633 | 3.344 | 1.425 |
| 当前 ROB4，同频 | 600 | 2032626 | 0.237518 | 3.388 | 1.459 |
| 当前 ROB4，合法频率 | 700 | 2251654 | 0.214667 | 3.217 | 1.347 |
| 原后端，ROB 关闭 | 680 | 2171419 | 0.222642 | 3.193 | 1.329 |

相对原 ROB4：同 600 MHz 下 Total 周期增加 1.30%，
Scored 周期增加 2.40%；各自合法频率下 Total 时间变化
-3.81%，Scored 时间变化 -5.52%。
百分比使用窗口周期/频率，表中毫秒是原生 timer 读数，避免短 test 的整数 tick 掩盖细小差别。
面积减少 0.73%，面积×Total 时间比为 0.9549。
相对于稳定原后端，该乘积比为 1.0312；本轮不据一个短测试更改默认架构。
不能把原 600 MHz 周期直接除以 700 MHz，因为外设/存储等待的 CPU 周期数也会变化。

独立混合 FU 镜像仍退休 1961 条，原 ROB4 5988 周期，当前 6118；原后端 6649。
量化 RV32IM 内核仍退休 151125 条，原 ROB4 191851 周期，当前 192354；原后端 192451。
它们使用 standalone flat memory，只用来检查边界开销与 FU 重叠，不当作 SoC 时间。
原始窗口、子测试、缓存流量及百分比见[机器可读比较](data/rv32-backend-timing-2026-09-29/comparison.json)。
同 600 MHz 下，整程序 I-cache 完成回填从 1987 增到 2062（+3.77%）；
D-cache 回填仍为 11934 次/47736 words，写回仍为 8010 次。取指时序改变也存在流量代价，
不能把此次修改描述成无代价优化。流量是整程序范围，不与 Total 窗口混算，也不把访问次数当作功耗。

## 正确性与复现

- 新增最近生产者参考检查：2/4/8 项各 10000 次，覆盖最近未完成写者不能被更老结果绕过、x0 与异常。
- 新增 fetch buffer 参考队列：直通开/关各 10000 拍，随机反压、flush、满队列同拍出入，
  并检查持续供给/接收时没有额外空拍。两种配置均通过。
- 最终 ROB4/load overlap：core、2803 个算术 oracle/DiffTest、40 个精确异常、100 个
  FENCE.I/clean-error/dirty-victim/错误 taken、定时中断、量化内核通过。
- 混合 FU/多版本结果检查及 36 个恢复/延迟 LSU 响应组合通过。已有断言和软件期望值未放宽。
- 未运行本轮完整 train、形式验证、布局布线或功耗分析。没有将 2/8 项随机输入验证说成同等整核覆盖。

从仓库根目录使用新的输出目录：

```sh
python3 npc/scripts/test_backend_input.py --output npc/result/backend-check/input
make -C npc git_commit= NPC_HOME="$PWD/npc" NPC_CONFIG=rv32im-pipelined \
  NPC_BACKEND_ROB_ENABLE=1 NPC_BACKEND_ENTRIES=4 NPC_BACKEND_LOAD_OVERLAP=1 \
  NPC_ASSERT_ENABLE=1 BUILD_DIR="$PWD/npc/result/backend-check/build" build-npc
python3 npc/scripts/verify_mul_pipeline.py --simulator npc/result/backend-check/build/top_sim \
  --backend-rob 1 --backend-entries 4 --load-overlap 1 --output npc/result/backend-check/checks
python3 npc/scripts/test_backend_core.py --simulator npc/result/backend-check/build/top_sim \
  --output npc/result/backend-check/mixed
python3 npc/scripts/test_backend_recovery.py --output npc/result/backend-check/recovery
python3 npc/scripts/measure_execute_ppa.py --output npc/result/backend-check/ppa \
  --name current --mul-pipeline 1 --backend-rob 1 --backend-entries 4 --load-overlap 1
python3 npc/scripts/run_microbench_perf.py --scale test --isa rv32im --mul-pipeline 1 \
  --backend-rob 1 --backend-entries 4 --load-overlap 1 --cpu-mhz 700 \
  --icache-bytes 1024 --icache-ways 4 --icache-line 32 --icache-policy 13
```

同频对照将最后一条的 CPU 频率改为 600；手动完整 train 将 `--scale test` 改为 `--scale train`，
其余参数不变。Capstone 不在默认目录时设置 `CAPSTONE_HOME` 指向现有安装。
[验证摘要和原始日志索引](data/rv32-backend-timing-2026-09-29/summary.json)记录命令、路径及 SHA256；
[取舍清单](data/rv32-backend-timing-2026-09-29/decision.json)列出保留、拒绝和未验证边界。
本地实验路径为 `npc/result/backend-timing-20260929/`。只保留必要报告、冻结源码和选中网表，
被拒绝候选的大型中间产物可重建；压缩报告保留在各候选 `raw-reports.tar.gz` 中。
本轮未提交、推送或合并。
