# RV32 定时中断版本综合与时序复测

日期：2026-09-06。分支 `rv32-interview`，基点 `bb03677d1ea6670059391328f1a61b69fb8f35ea` 加当前工作树改动。综合与 STA 均退出 0，运行期间源码哈希未变化。

> 后续 D-cache 优化已得到新结果：79,324.658 μm²，820 MHz setup WNS +0.083 ns、TNS 0；复位 removal 仍未通过。本文保留优化前基线，最新工作树见 [时序优化报告](RV32_TIMING_FIX_2026-09-06.md)。

## 结果

| 指标 | 历史网表复查 | 当前工作树 | 变化 |
| --- | ---: | ---: | ---: |
| 标准单元映射面积 | 69,448.610 μm² | **78,942.150 μm²** | +9,493.540 μm²，**+13.67%** |
| 报告估算 Fmax | 766.875 MHz | **820.127 MHz** | +53.252 MHz，**+6.94%** |
| 1 GHz 约束下 setup WNS | −0.304 ns | −0.219 ns | 最差违例改善 0.085 ns |
| setup TNS | −457.502 ns | −834.600 ns | 总负裕量增加 |
| 时序单元面积 | 33,859.140 μm² | 43,276.072 μm² | +9,416.932 μm² |
| DFF 数量 | 7,383 | 9,361 | +1,978 |

历史映射网表通过同一 NanGate45 库重新统计面积，并用同一 SDC/iSTA 重跑时序，完整复现原记录的面积、频率、WNS 和 setup TNS。因此这里的旧数值不只来自文档抄录。历史源码提交标识仍是 `uncommitted`，不能把旧网表认定为 bb03677 的精确综合产物。

当前仍未满足 1 GHz 约束。820.127 MHz 是报告按最差路径给出的估算，不是重新在 820 MHz 约束下完成时序收敛，也不是布局布线后的签核频率。min 报告仍有违例，其中报告最差路径是异步复位 removal 检查（当前 min TNS −224.386 ns，历史 −116.840 ns）；此次没有 CTS、布线或时序修复。Fmax 改善不能解释成所有时序指标都改善，setup TNS 实际变差。

## 面积变化来自哪里

增加的总面积约 9,493.54 μm²，其中时序单元面积增加约 9,416.93 μm²。新旧网表的寄存器分布明显不同：预测器 DFF 实例从 1,171 增至 1,723，IFU 从 69 增至 276；当前还存在更多译码、寄存器读取、执行结果与重定向寄存状态。

这些是映射网表中按实例名前缀统计的观察值，综合可能跨层优化或改名，不能当成独立模块面积。**本次比较的是历史网表与当前完整实现，不能把 +13.67% 全部归因于定时中断。** 要单独量化中断开销，需要对精确的 bb03677 源码再做一次相同流程的综合；本次没有把这一额外实验混入结果。

当前最差 setup 路径从 D-cache 的 `lookup_s1_q` 出发，到 `u_data_array.data_array_q` 的 D 端，报告到达时间 1.166 ns、要求时间 0.947 ns。历史最差路径终点是 LSU `state_q`。当前瓶颈已不能只按旧报告中的 EXU→LSU 路径描述。

## 配置、工具和统计边界

- 顶层：`riscv32_core`，包含核内中断受理/CSR、预测器、流水线及 I/D-cache；**不包含核外 CLINT 和 SoC**。
- `rv32-baseline`：XLEN32；I-cache 256 B/1 路/16 B 行；D-cache 256 B/2 路/16 B 行；BHT16、BTB16×2、RAS4。
- NanGate45 `Nangate45_typ.lib`；标准单元映射，未使用物理 SRAM 宏替代缓存阵列。
- 1 GHz 约束，`DELAY 0`，时钟端口 `clk_i`，项目原 SDC；未启用功耗分析。
- Yosys 0.60+70（8101c87fa）+ Slang；iEDA/iSTA GitVersion `aa25008b3778a76ae1975c839d4cc459f7f7b3b7`。**实际执行的 STA 不是 OpenSTA**，简历工具名称已据此修正。
- 恢复提交所固定的 yosys-sta 仓库较旧，缺少当前 SystemVerilog/Slang 入口及本地 PDK/工具。此次从已有工作环境复制实际可用的 Makefile 和 Tcl 到独立 `toolflow`，记录哈希；PDK 与工具二进制只读引用已有安装。

## 复核材料

所有材料保存在 [本次结果目录](../../result/sta/rv32-interrupt-20260906/)：

- [当前面积报告](../../result/sta/rv32-interrupt-20260906/riscv32_core-1000MHz/synth_stat.txt)
- [当前时序报告](../../result/sta/rv32-interrupt-20260906/riscv32_core-1000MHz/riscv32_core.rpt)
- [历史网表面积复查](../../result/sta/rv32-interrupt-20260906/historical-netlist/area.log)
- [历史网表时序复查](../../result/sta/rv32-interrupt-20260906/historical-netlist/riscv32_core.rpt)
- [数值对比 JSON](../../result/sta/rv32-interrupt-20260906/comparison.json)、[输入及工具哈希](../../result/sta/rv32-interrupt-20260906/manifest.json)
- `source_snapshot/`、`working-tree.patch`、`toolflow/`、`versions.txt`、`run.log`。

原始运行命令（工作目录为 `ysyx-workbench-rv32-interview`，目录中的 toolflow 已准备）：

```bash
export NPC_HOME="$PWD/npc"
make -C npc NPC_CONFIG=rv32-baseline git_commit= sta \
  STA_FREQUENCY_MHZ=1000 STA_SYNTH_STRATEGY='DELAY 0' \
  STA_TOOL_DIR="$PWD/npc/result/sta/rv32-interrupt-20260906/toolflow" \
  STA_OUTPUT_ROOT="$PWD/npc/result/sta/rv32-interrupt-20260906"
```

再次运行可能复用已有网表；开展新实验时换一个输出目录，并先核对源码/配置哈希，保留本次结果。本次没有重跑 IPC，不能将历史 IPC 与当前 Fmax 相乘后声称得到当前处理器实测吞吐。

## 同一网表在 820 MHz 下复查

按用户要求仅把时钟约束改为 820 MHz，复用上述 1 GHz 综合出的映射网表，没有重新综合或修改 RTL。两份网表 SHA-256 相同，因此面积仍为 78,942.15 μm²。使用同一 Tcl、库和 SDC，iSTA 正常退出 0。

| 检查 | 1 GHz | 820 MHz |
| --- | ---: | ---: |
| Setup WNS | −0.219 ns | **−0.000 ns（报告显示精度）** |
| Setup TNS | −834.600 ns | **−0.992 ns** |
| Min 最差 slack | −0.106 ns | **−0.062 ns** |
| Min TNS | −224.386 ns | **−130.655 ns** |
| 门控时钟最差 max slack | −0.135 ns | +0.084 ns |
| 门控时钟最差 min slack | +0.101 ns | +0.101 ns |

**820 MHz 仍未达到零时序违例。** 负零显示不能解释成通过：路径标记为 `slack (VIOLATED)`，且 setup TNS 仍为负。820.127 MHz 是工具估算，不能替代实际约束下的检查。当前输出仅保留三位小数，无法据此准确还原最小负裕量；未进一步证明估算值与实跑之间的数值精度/量化原因。

最差 min 路径从 `rst_ni` 到寄存器 `RN`，详细项为 `library removal time`；此前将这类结果统称为 hold 不够精确，应单独检查异步复位释放与约束。SDC 将输入延迟设为周期的 20%，所以从 1 GHz 改到 820 MHz 也使输入延迟从 0.200 ns 变为约 0.244 ns，这解释了复位 min 报告数值的变化，不表示降频修复了硬件 hold 问题。原 SDC 的复位 false-path 保持不变，报告仍列出 removal 违例；本次没有为消除违例而改动约束。

材料：[820 MHz 完整报告](../../result/sta/rv32-interrupt-20260906/same-netlist-820MHz/riscv32_core.rpt)、[日志](../../result/sta/rv32-interrupt-20260906/same-netlist-820MHz/sta.log)、[命令/环境/网表哈希](../../result/sta/rv32-interrupt-20260906/same-netlist-820MHz/run.json)、[结果摘要](../../result/sta/rv32-interrupt-20260906/same-netlist-820MHz/summary.json)。
