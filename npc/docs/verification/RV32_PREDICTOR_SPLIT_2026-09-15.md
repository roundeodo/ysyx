# RV32 预测器模块拆分与验证

日期：2026-09-15。工作树 `ysyx-workbench-rv32-interview`，分支 `rv32-interview-20260911`。
源码基点为 `4d0716eb221ad49d4dd88890f6d2ddb7fdd11604`，同时保留此前取消 RR 的工作树改动。
本次只拆分预测器的状态归属和接口，未改变预测算法、容量、查询流水级数或训练生效时刻。

## 实现

| 文件 | 行数 | 职责 |
| --- | ---: | --- |
| `riscv32_fetch_control_flow_predictor.sv` | 268，原为 700 | 查询握手与流水控制、PC/epoch 对齐、最终预测选择、共享解析事件寄存 |
| `riscv32_branch_history_table.sv` | 54 | 方向计数器数组、查询和条件分支训练 |
| `riscv32_branch_target_buffer.sv` | 319 | 目标表、替换、查询 set 快照、tag 比较、训练流水和训练旁路 |
| `riscv32_return_address_stack.sv` | 184 | 调用/返回识别、栈操作寄存和返回地址栈 |

四个文件均位于 `vsrc/riscv32/core/frontend/`。新增端口和模块声明使总行数增加；
每组数组、更新和断言现在有明确归属，不再需要跨整个原文件追踪同一个功能。
共享包只增加 `branch_target_kind_e`，BTB 内部索引、表项和训练事务类型留在 BTB 模块中。
仿真、STA 文件列表和流水线测试的源码列表已同步加入三个新模块。

详细契约见 [预测器设计记录](../microarchitecture/FETCH_PREDICTOR_DESIGN_RECORD.md)。
原注释中“BTB/BHT 查询能旁路到最新训练值”的表述已修正；实际仅 BTB 的训练快照有待写事务旁路。

## 逐周期对照

新增 `test-predictor-equivalence`，在相同输入下比较拆分前后所有外部输出，包括 ready、valid、
PC、epoch、完整 prediction 和 next PC。对照在每拍上升沿之前及之后各执行一次，
并检查有效响应在反压期间的稳定性。它是仿真对照，不是形式等价证明。

参考源码从上述固定 Git 版本提取，仅将模块名改为测试专用名称；SHA-256 为
`d1cfc006634e019ebe795be3e900768203b0d5145a22d1ec2b84902f066ecaa6`。
参考模块生成在测试输出目录，不进入 CPU 的仿真/综合文件列表，不维护第二份活动 RTL。

| BHT 项数 | BTB 总项数 | BTB 路数 | RAS 项数 | 对照周期 | 结果 |
| ---: | ---: | ---: | ---: | ---: | --- |
| 16 | 16 | 2 | 4 | 24,000 | 通过，当前默认配置 |
| 16 | 16 | 1 | 4 | 24,000 | 通过 |
| 16 | 16 | 4 | 4 | 24,000 | 通过 |
| 2 | 4 | 2 | 2 | 24,000 | 通过 |
| 64 | 32 | 2 | 8 | 24,000 | 通过 |

共 120,000 周期，包含确定性连续训练与伪随机查询/训练：同 set 不同 tag、重复更新同 PC、
BHT 上下饱和、RAS 溢出/下溢及 pop+push、未对齐目标、反压、flush、独立 invalidate、
查询和训练同拍，以及运行中再次复位。测试统计查询、响应、taken、停顿、清空及训练次数，
低于预设覆盖数量会失败。这些参数用来检查拆分边界，不代表五组配置均完成全核 PPA 或 train 验证。

## 完整 CPU 验证与性能对照

- Verilator lint 及原有流水线回归通过；项目仍有既有警告，不宣称零警告。
- 定时中断回归通过：3 组汇编系统用例、2 组 AM 系统用例，以及 CLINT、中断控制、IFU 重定向单元测试。
- 750 MHz 配置的 SoC MicroBench `test`：十项 PASS、GOOD TRAP。

同一频率、相同设备延迟模型下，拆分前后测量结果完全一致：

| 窗口 | CPU 周期 | 退休指令 | IPC | 原生定时器用时 |
| --- | ---: | ---: | ---: | ---: |
| Total | 4,828,640 | 763,521 | 0.158123405 | 0.006438 s |
| Scored | 2,168,036 | 430,313 | 0.198480560 | 0.002891 s |

全部十个子测试窗口和从复位到退出的 whole_program 统计也一致。本次没有重新运行 train，
不能给出新的 train 成绩。750 MHz 在这里首先是 RTL 功能/周期对照的计时配置；物理可用频率
必须结合下面对应网表的 STA，不能由 Verilator 正常运行推出。

补充运行了 675 MHz 的 MicroBench `test`，十项通过：Total 为 0.006715 s / IPC 0.168578338，Scored 为 0.003026 s / IPC 0.210612019。原始数据见 `microbench-test-675/report.json`；它用于核对降频后的计时配置，不能和 750 MHz 的 IPC 差值一起当作模块拆分的收益。

## 综合与时序对照

使用 Yosys/Slang、NanGate45 typical 库、`DELAY 0` 和 iEDA/iSTA；统计边界为纯核、
复位控制器及相同策略生成的复位缓冲树，不含 CLINT/SoC，未进行布局布线或寄生提取。

| 实现与映射目标 | mapped cell area（μm²） | 报告估算 Fmax | 说明 |
| --- | ---: | ---: | --- |
| 拆分前，820 MHz 综合目标 | 76,585.656 | 760.556 MHz | 引用同日取消 RR 后的测量；该网表在 750 MHz 下通过 |
| 拆分后，750 MHz 综合目标 | 76,479.522 | 688.926 MHz | 750 MHz setup slack −0.119 ns；同网表降到 675 MHz 后为 +0.029 ns，全部时序检查通过 |
| 拆分后，820 MHz 综合目标 | 76,480.320 | 742.966 MHz | 相同综合目标对照；820 MHz setup slack −0.127 ns |

最终采用上述 820 MHz 目标生成的网表，降到 **730 MHz** 检查：setup slack **+0.023 ns**，
hold slack **+0.059 ns**，门控时钟 max/min slack **+0.188 / +0.097 ns**，全部通过。
该网表与 `sta-same-constraints/riscv32_core_reset_boundary-820MHz-buffered/` 中的网表
逐字节一致，730 MHz 只改变 STA 时钟约束。后续正常性能测试显式传 `--cpu-mhz 730`；
本次没有运行 730 MHz 的 MicroBench，前述 750 MHz 数值用于同频 RTL 行为对照。

两组新综合结果的触发器数量与拆分前相同：DFFR_X1 为 1,164，DFFS_X1 为 24，DFF_X1
为 7,681，共 8,869 个。模块拆分没有增加流水寄存级，面积变化约 −0.14%，没有面积增加。

相同综合目标下估算 Fmax 降低约 2.31%。最终关键路径从取指缓冲 `read_index_q` 经
组合读取/译码与操作数选择到 ID/EX 的 `execute_packet[93]`。可以确认新的映射结果不同，
不能把所有时序变化直接归因于 BHT/BTB/RAS 查询路径；本次没有继续做后端时序优化。
第一次新综合改用了 750 MHz 目标，因此额外补了原来的 820 MHz 目标对照，
避免把不同 ABC 映射目标的结果混为同条件实验。

综合命令，在工作树根目录、已设置 `NPC_HOME` 后运行：

```bash
make -C npc git_commit= NPC_CONFIG=rv32-baseline sta-reset \
  STA_FREQUENCY_MHZ=820 STA_SYNTH_STRATEGY='DELAY 0' \
  STA_TOOL_DIR="$PWD/npc/result/sta/rv32-interrupt-20260906/toolflow" \
  STA_OUTPUT_ROOT="$PWD/npc/result/performance/predictor-split-20260915/sta-same-constraints"
```

同一映射网表降频检查时，复制 buffered 网表及 SDC 到独立目录，用
`NPC_STA_NETLIST_FILE=<网表绝对路径> CLK_FREQ_MHZ=<检查频率> RUN_POWER_ANALYSIS=0`
调用该工具目录的 `bin/iEDA -script scripts/sta.tcl <SDC> <网表> riscv32_core_reset_boundary nangate45`。
SDC 从环境变量读取频率；原始结果文件按频率分别保留，不覆盖此前测量。

## 原始数据与复现

所有结果保存在
[`result/performance/predictor-split-20260915`](../../result/performance/predictor-split-20260915/)：

- `predictor-before.sv`、`rtl-before.tar.gz`、`working-tree-before.patch`：修改前源码与工作树状态。
- `equivalence/`：参考源码、编译/运行日志、命令与源文件 SHA-256。
- `regression.log`、`timer-regression.log`：模块及系统回归。
- `microbench-test-750/report.json`、`manifest.json`、源码快照：拆分后短测。
- 拆分前性能对照：`../rv32-remove-rr-20260915/microbench-final-750/report.json`。

在面试工作树根目录运行：

```bash
export NPC_HOME="$PWD/npc"
export AM_HOME="$PWD/abstract-machine"
make -C npc git_commit= NPC_CONFIG=rv32-baseline \
  test-predictor-equivalence lint-npc test-pipeline test-timer-interrupt
python3 npc/scripts/run_microbench_perf.py --scale test --cpu-mhz 730 \
  --output npc/result/performance/predictor-split-test-repeat
```

MicroBench 输出目录必须尚不存在。浅克隆缺少参考 Git 对象时，脚本支持 `--reference` 指定
归档的 `predictor-before.sv`，并校验相同 SHA-256；配置宏仍需从 Makefile 提供。
若要复现本记录的同频功能对照，单独改用 `--cpu-mhz 750`；它不表示该频率已经通过新网表时序。
