# RV32 D-cache 写数据路径优化

日期：2026-09-06。范围：`rv32-interview` 当前小缓存纯核，修复前基线为当日加入定时中断后的 78,942.15 μm² / 820.127 MHz 网表。

> 后续复位及重定向修复已完成 820 MHz 综合后时序检查，本文保留 D-cache 阶段的结果。最新状态见 [复位与重定向修复](RV32_RESET_REDIRECT_FIX_2026-09-06.md)。

## 改动与行为边界

原写数据选择依赖 `store_hit_write_occurred`，把命中判断、响应握手等晚到控制接到了 32 位写数据选择器上。修改后，写数据仅按 `miss_data_write_valid` 选择：miss/refill 有效时使用其数据，否则预选已寄存的 store 数据。

真正写入仍由原 `data_write_valid`、地址、way、字节使能决定，miss/refill 优先级保持原样。没有增加流水级，也没有提前确认 store。现有 read-during-write bypass 保留。

这项改动成立的条件可以分三种情况检查：miss 写有效时新旧均写 miss 数据；只有 store 写有效时新旧均写 store 数据；二者均无效时阵列不采样写数据。源码中这个数据端口只连接 data array，因此空闲时载荷变化不会成为额外响应。

## 实测结果

本轮改动保留。相同工具、配置、约束下，面积增加 382.508 μm²（0.48%），报告 Fmax 提高约 7.34%。

| 指标 | 修复前 | 修复后 |
| --- | ---: | ---: |
| 映射面积 | 78,942.150 μm² | 79,324.658 μm² |
| 时序单元面积 | 43,276.072 μm² | 43,276.072 μm² |
| 报告估算 Fmax | 820.127 MHz | 880.318 MHz |
| 1 GHz setup WNS | −0.219 ns | −0.136 ns |
| 1 GHz setup TNS | −834.600 ns | −130.643 ns |
| 820 MHz setup WNS | −0.000 ns | **+0.083 ns** |
| 820 MHz setup TNS | −0.992 ns | **0.000 ns** |
| 820 MHz 门控时钟最差 max slack | +0.084 ns | +0.078 ns |
| 820 MHz 门控时钟最差 min slack | +0.101 ns | +0.097 ns |
| 820 MHz 最差 min slack（复位 removal） | −0.062 ns | −0.062 ns |
| 820 MHz min TNS | −130.655 ns | −130.655 ns |

820 MHz 的 setup 和已报告门控时钟检查通过，复位 removal 仍未通过，因此不能声称全设计时序收敛。1 GHz 仍有 setup 和门控时钟 max 违例。880.318 MHz 是报告的 core_clock 路径估算，未在该频率重新 STA，也不代表门控时钟、复位及物理时序均满足。

新最差 setup 路径为 `execute_redirect_req_at_resolution_12__reg_p:Q → frontend_recovery_occurred_reg_p:D`，到达时间 1.093 ns。D-cache 数据阵列不再占据报告前五条最差 setup 路径；后续若继续提高频率，应检查重定向解析到前端恢复的组合控制深度。

原 D-cache 测试、扩展 D-cache 测试，以及中断回归全部通过。中断回归包含 3 组汇编系统测试、2 组 AM 系统测试和 3 组单元测试，共受理 43 次定时中断。本轮没有运行全核形式等价或新 IPC 基准。扩展测试第一次运行遇到 testbench 在改变 ready 的同一仿真时刻立即采样组合输出的问题；加入采样前的稳定等待后通过，日志保留为 `dcache-extended.log` 和 `dcache-extended-rerun.log`。

统计边界仍为 NanGate45 标准单元映射的 RV32 小缓存纯核，不含 CLINT/SoC，不含布局布线寄生参数。输入快照、哈希、原始报告和 `summary.json` 均保存在结果目录。

## 验证和复现

运行现有 D-cache directed test 与完整定时中断回归；扩展 D-cache 用例检查部分字节 store、连续三拍响应背压、同拍接受后续 load 的 bypass，以及后续普通 load 的阵列内容。综合输入哈希与上一轮比较，只有 `riscv32_dcache.sv` 改变；SDC、配置、库、综合策略均保持一致。

```bash
export NPC_HOME="$PWD/npc"
make -C npc NPC_CONFIG=rv32-baseline git_commit= test-dcache test-timer-interrupt
make -C npc NPC_CONFIG=rv32-baseline git_commit= sta \
  STA_FREQUENCY_MHZ=1000 STA_SYNTH_STRATEGY='DELAY 0' \
  STA_TOOL_DIR="$PWD/npc/result/sta/rv32-interrupt-20260906/toolflow" \
  STA_OUTPUT_ROOT="$PWD/npc/result/sta/rv32-timing-fix-20260906"
```

以上命令在 `ysyx-workbench-rv32-interview` 运行。新实验应另选输出目录，保留已完成产物。820 MHz 检查复用新综合网表，只重新运行 STA，具体命令见结果目录的 `same-netlist-820MHz/run.json`。

## 复位问题的处理边界

本次数据路径优化不改变复位 RTL 或原 SDC。原报告最差 min 路径是 `rst_ni → RN` 的 removal 检查，不能用数据路径 setup 的改善声称它也已修复。

另外运行了单个 NanGate45 `DFFR_X1` 的约束探针：验证 iSTA 能识别 `set_input_delay -clock_fall -min/-max`，并报告复位 recovery/removal。探针只是工具能力检查，下降沿后的 0.05–0.15 ns 是假设输入预算；当前系统没有实现对应的复位释放电路，不能将该假设直接套用全核来消除违例。

后续复位修复需要在系统边界实现并验证异步置位、同步释放，明确释放相位及到核内复位端的最小/最大延迟，同时检查时钟门控与复位树。仅添加 false-path 或任意调整输入延迟不能作为硬件修复证据。

结果目录：[rv32-timing-fix-20260906](../../result/sta/rv32-timing-fix-20260906/)。历史基线见 [中断版本 PPA 复测](RV32_INTERRUPT_PPA_2026-09-06.md)。
