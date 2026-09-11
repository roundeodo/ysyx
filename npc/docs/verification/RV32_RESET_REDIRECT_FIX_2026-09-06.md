# RV32 复位与重定向时序修复

日期：2026-09-06，工作区 `ysyx-workbench-rv32-interview`。接续 [D-cache 优化](RV32_TIMING_FIX_2026-09-06.md)。

**结果：包含实际复位控制器及复位缓冲树的纯核边界，在 NanGate45、820 MHz、当前综合后 STA 条件下，core_clock max/min TNS 均为 0，门控时钟 max/min 裕量为正。** 没有完成 CTS、布线及多工艺角签核；不能把此结果写成芯片实测频率或 1 GHz 收敛。

## 改了什么

1. EX/MEM 入口保存预测后继 PC。原来输出侧的 PC+4 和选择逻辑提前到寄存器入口，输出侧直接比较实际后继与寄存的预测后继。原指令 payload、握手及 flush 优先级不变，没有增加流水级。
2. 系统入口新增唯一的 `riscv32_reset_controller`，两级上升沿同步、下降沿统一释放。核、CLINT、总线仲裁/路由与 SoC 位宽转换器共享该释放结果。原始复位异步拉低时仍立即进入复位。
3. 综合后给复位释放网络加入 96 个 `BUF_X4`，限制新增缓冲树的每级扇出为 16。它增加 178.752 μm²；原始网表、未缓冲时的失败报告保留。脚本通过结构比较证明，只把原释放信号换成非反相缓冲后的同一信号，没有改变原单元的逻辑连接。
4. 新增 `make test-timing`、`make sta-reset`，以及复位连接审计脚本。普通 `make sta` 保留原纯核统计入口。

## 时序和面积

### 最终验收边界：纯核、复位控制器、复位缓冲树

| 指标 | 820 MHz 实测 |
| --- | ---: |
| 标准单元映射面积 | **79,002.532 μm²** |
| core_clock 最差 max slack | **+0.036 ns** |
| core_clock max TNS | **0.000 ns** |
| core_clock 最差 min slack | **+0.059 ns** |
| core_clock min TNS | **0.000 ns** |
| 门控时钟最差 max slack | **+0.035 ns** |
| 门控时钟最差 min slack | **+0.099 ns** |

顶层是 `riscv32_core_reset_boundary`，不包含 CLINT 和 SoC。最差 max 终点是 I-cache 的 `local_lookup_resp` 寄存器。该网表报告 Fmax 845.239 MHz；本轮只以实际运行的 820 MHz 作为验收点，不把估算值当作已通过的频率。

没有缓冲树时，释放寄存器直接驱动 1,205 个输入端，报告 Q 端负载约 2.129 pF、转换时间约 4.860 ns，导致复位 recovery 及门控时钟路径严重违例。加入树后，检查到 1,161 个核内 RN 均由合格的释放网络驱动；原始 rst_ni 仅连接同步链的三个 RN。同步输出到核内 RN 的检查保留在 STA 中。

### 单独观察重定向优化：保持原纯核边界及 SDC

| 指标 | 上轮 D-cache 优化后 | 本轮重定向优化后 |
| --- | ---: | ---: |
| 纯核映射面积 | 79,324.658 μm² | **78,871.394 μm²** |
| 报告估算 Fmax | 880.318 MHz | **903.898 MHz** |
| 1 GHz setup WNS | −0.136 ns | −0.106 ns |
| 1 GHz setup TNS | −130.643 ns | −29.463 ns |
| 同一综合网表在 820 MHz 的 setup WNS | +0.083 ns | +0.113 ns |

这里两轮都以 1 GHz 综合，再对同一网表复查 820 MHz；原纯核 SDC 将复位按同步输入建模，因此此对照仍显示旧式 removal 违例。最终验收应看上面的真实复位边界，不能把这份对照报告当作新的系统复位验收。

最终边界则在 820 MHz 综合，额外包含复位电路，映射选择也发生变化。**不能用两张表的面积或频率差值直接计算复位控制器开销。** 缓冲树的 178.752 μm² 来自同一网表插入前后的精确增量。1 GHz 仍未收敛，约 904 MHz 也只是原纯核报告估算，不能作为系统承诺。

## 验证与约束边界

- 复位测试通过：停钟时异步置位、不同释放相位、两次上升沿后在下降沿释放、同步中再次复位重新计数。
- 执行结果测试通过：1,024 组方向/目标比较、PC 加法回绕、payload、背压和 flush 场景。
- 现有流水控制测试通过。
- 完整中断回归通过：3 组汇编系统测试、2 组 AM 系统测试、3 组单元测试，共受理 43 次中断；新增检查系统释放前不得发出 AXI 请求。
- NPC AXI 顶层 lint 退出 0，仍有未使用信号/空端口等告警；映射网表 `check -mapped` 为 0 problems。
- 缓冲树结构等价和复位连接审计通过；本轮没有运行全核形式等价、全量 ISA/DiffTest、新 IPC 基准或 ysyxSoC/RT-Thread 回归。

新 SDC 对全部 101 个标量数据输入设置原来的 20% 周期输入延迟。原始异步 rst_ni 不指定虚构的同步到达时间，其三个同步器 RN 不是同步 STA 的验收端点。同步链及输出驱动电路由真实网表产生时序路径，核内 RN 继续进行 recovery/removal 检查。这里没有对整个复位网络设置 false-path，也没有把复位端口延迟随意调大来消除违例。

同步器降低亚稳态传播风险，但数字功能仿真和当前单工艺角 STA 不等于亚稳态 MTBF、复位脉宽或物理复位树签核。系统入口同步复位的依据可参阅 [Intel 的复位同步说明](https://www.intel.com/content/www/us/en/docs/oneapi/programming-guide/2023-2/ip-component-reset-behavior.html)。

## 复现

在 `ysyx-workbench-rv32-interview` 运行，工具路径沿用已保存的可用工具流：

```bash
export NPC_HOME="$PWD/npc"
make -C npc NPC_CONFIG=rv32-baseline git_commit= test-timing test-pipeline test-timer-interrupt
make -C npc NPC_CONFIG=rv32-baseline git_commit= sta-reset \
  STA_FREQUENCY_MHZ=820 STA_SYNTH_STRATEGY='DELAY 0' \
  STA_TOOL_DIR="$PWD/npc/result/sta/rv32-interrupt-20260906/toolflow" \
  STA_OUTPUT_ROOT="$PWD/npc/result/sta/rv32-reset-redirect-20260906/reset-boundary" \
  STA_RESET_OUTPUT_DIR="$PWD/npc/result/sta/rv32-reset-redirect-20260906/reset-buffered-820MHz"
```

此目标先保留未缓冲的综合/STA 产物，再生成和审计缓冲网表，最后执行缓冲后的 STA。未缓冲报告预计会有高扇出复位违例，最终结果应读取 `STA_RESET_OUTPUT_DIR`。进行新的实验时换输出目录。

材料位于 [结果目录](../../result/sta/rv32-reset-redirect-20260906/)：`summary.json`、输入快照与哈希、回归日志、`core/`、`core-same-netlist-820MHz/`、`reset-boundary/`、`reset-buffered-820MHz/`。脚本调试中出现的枚举名称和综合重命名识别问题已修正，原始失败日志保留，不能把它们与最终通过的回归日志混为一谈。
