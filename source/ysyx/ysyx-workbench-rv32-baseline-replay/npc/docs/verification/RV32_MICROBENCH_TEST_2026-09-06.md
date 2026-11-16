# 当前 RV32 MicroBench test 性能基线

日期：2026-09-06。工作区 `ysyx-workbench-rv32-interview`，基点 `bb03677d1ea6670059391328f1a61b69fb8f35ea` 加当前未提交改动。被测 CPU RTL 哈希与上一轮复位/重定向时序验收一致，本轮没有修改 CPU RTL。

## 结果

MicroBench `test` 的 10 个子测试全部 Passed，程序输出 `MicroBench PASS` 和 `HIT GOOD TRAP`，命令退出 0。

| 统计口径 | 退休指令 | 周期 | IPC |
| --- | ---: | ---: | ---: |
| **PMU 计分窗口** | **430,203** | **1,643,700** | **0.261728** |
| C++ 仿真器整次运行 | 822,308 | 3,617,798 | 0.227295 |

PMU 值为各子测试 `run()` 前后 mcycle/minstret 快照差值的累计，包含读取快照的少量开销，不是整个启动、准备、验证、打印过程的平均值。RV32 使用 high-low-high 读取方式处理 64 位计数器。IPC 已由原始指令数除以周期数独立复算，不能混用两种窗口。

原 [实验日志](EXPERIMENT_LOG.md) 的历史 `test` 记录为 430,203 条指令、1,194,972 周期、IPC 0.360010。当前退休指令数相同，周期增加 **37.55%**，IPC 降低 **27.30%**。历史 CPU 源码标识是 `uncommitted`，而本轮还恢复了 SoC 和软件计数依赖，因此这不是隔离单项 RTL 变化的前后对比。不能把差异直接归因于复位、重定向优化或中断功能。**当前实现通过功能/时序测试，不代表已经达到历史 IPC。**

本次使用 `test` 规模；没有运行正式 `train`，也没有启用 DiffTest。

## 配置与恢复的依赖

- RV32I 小缓存配置 `rv32-baseline`：I-cache 256 B、1 路、16 B 行；D-cache 256 B、2 路、16 B 行；BHT16、BTB16×2、RAS4。
- 平台 `riscv32-ysyxsoc-sdram`，AXI SDRAM 原生读 burst；软件按 `mainargs=test` 重编译。
- 恢复分支原先缺少 `ysyxSoC/build/ysyxSoCFull.v`、AXI SDRAM 等配套修改，以及 MicroBench PMU 窗口代码。这些文件从同一 SoC 基点的已有兄弟工作区恢复，SoC 生成文件只把 CPU 实例模块名改为 `riscv32_npc_axi`；原兄弟工作区未修改。恢复后的文件和差异均留有哈希/patch。
- Capstone 只读复用兄弟工作区的已有构建；没有改变核心配置或使用 RV64 CPU 替代测试。

复现命令（从该工作区根目录运行）：

```bash
NPC_HOME="$PWD/npc" AM_HOME="$PWD/abstract-machine" NEMU_HOME="$PWD/nemu" \
make -C npc NPC_CONFIG=rv32-baseline git_commit= \
  CAPSTONE_HOME=/home/yong/ysyx/ysyx-workbench/nemu/tools/capstone/repo \
  perf PERF_SCALE=test
```

结果目录：[rv32-microbench-test-20260906](../../result/performance/rv32-microbench-test-20260906/)。最终日志 `run-capstone.log`，数值 `result.json`，输入及镜像哈希 `manifest.json`，恢复记录 `soc-recovery.json`、`soc.patch`、`benchmark-recovery.json`、`microbench.patch`。原先缺少 SoC 文件和 Capstone 的失败日志保留；最终运行已通过。

## 性能定位线索

> 后续代码审计发现：性能监视器的 `instruction_decode_occurred_i` 实际连接 IDU 输出握手，注释和执行计时却仍按 ID/EX 单条指令上下文解释。当前多级流水允许多个在途指令，新的译码会覆盖旧计时上下文。因此下面的停顿比例只可作为混合流水边界下的线索，不能作为已验证的执行发射槽分解；日志中的指令分类平均执行周期及 oracle/ideal speedup 不应作为优化上限。PMU mcycle/minstret 计分 IPC 独立于该监视器，仍有效。

以下是整个 active-core 窗口的监视器统计，不是 PMU 计分窗口内的比例：LSU structural stalls 24.872%、control recovery stalls 18.952%、frontend supply stalls 15.475%。I-cache 命中率 96.543%，平均 miss 关键响应延迟 28.005 周期；D-cache 命中率 84.522%，平均 miss 响应延迟 57.650 周期。

这些结果支持下一步检查 LSU 等待和控制恢复的周期损失。它们不是已经证明的历史 IPC 差异原因；应在同一 SoC、同一二进制下做局部版本对照，才能定位。

## 资源还能节省吗

有候选方向，但本轮只分析，没有再修改 RTL 或重新综合面积。上一轮纯核统计为 78,871.394 μm²：触发器面积 43,271.550 μm²（54.86%）；I-cache 数据阵列的 2,048 个 DLH_X1 共 5,447.680 μm²。两类存储单元合计约占 61.77%。包含复位控制器/缓冲树的最终边界面积仍引用上一轮实测 79,002.532 μm²。

优先检查各流水级宽 payload 的实际消费者，以及 D-cache miss unit/AXI 写回模块之间保存上下文的必要性。删除状态前须证明其在背压、写回错误和 flush 期间不再需要。综合已会删除无消费者的字段，所以不能拿源码结构体的宽度直接计算可节省面积。

D-cache 数据阵列仍有 2,048 个触发器，是存储实现方面的候选；但历史通用动态索引锁存数组实验已失败，后续只能针对静态 bank 或实际可用 SRAM 宏重新设计和验证。当前 I-cache 已采用锁存器，不能把它误当作尚未优化的触发器阵列。任何节省比例都应以完整综合结果为准，同时保持性能与时序验收。


## 瓶颈代码审计补充

- `riscv32_pipeline_hazard_controller.sv` 中 `execute_progress_allowed_o = !execute_result_stalled && !lsu_busy_i`，说明老访存未完成时，年轻的无关运算也不能进入执行。这是已确认的阻塞式顺序执行策略；D-cache miss/写回延迟会沿此路径影响吞吐。解除限制必须配套顺序提交与异常/中断处理，不能只删除 busy 条件。
- 当前预测校验在 EX/MEM 之后完成，重定向还经过 `riscv32_frontend_redirect_register`。错误路径恢复需重新经过前端及译码/读寄存器级。日志记录 51,624 次执行级纠错，控制恢复值得优先测量；现有停顿计数不能直接当作准确的每次误预测代价。
- I-cache miss 关键响应平均 28.005 周期，D-cache miss 响应平均 57.650 周期。不能因前端子分类仅记了 202 个 miss-service 周期就断言 I-cache 不重要：该分类优先把请求背压计入 backpressure，miss 可能在这段时间持续阻塞。
- 历史 69,448.61 μm² 网表包含 7,383 个 DFF，当前纯核有 9,360 个；IFU、预测器及流水级状态分布不同。该证据只能说明两个实现并非仅差一个中断入口，不能单凭寄存器数量解释 448,728 个计分窗口额外周期。

下一步应先对齐监视器的流水事件与 PMU 计分窗口，再固定 SoC 和程序镜像做版本对照。本轮没有修改 RTL 或重新运行程序。
