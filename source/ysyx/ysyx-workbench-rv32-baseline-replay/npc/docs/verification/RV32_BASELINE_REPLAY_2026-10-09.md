# 旧 RV32 硬件在统一环境下重测

> 历史配置与测量记录。2026-10-11 replay 默认已接入正式混合预测；当前配置和启动命令见
> [接入记录](RV32_REPLAY_HYBRID_2026-10-11.md)。本文旧面积不代表新组合。

恢复位置：`/home/yong/ysyx/ysyx-workbench-rv32-baseline-replay`。
硬件为前端探索开始前的 `e3b018f34b62f7f22ea5b7b7bd59611f7c5b6ff7`，
恢复时全部 68 个 `npc/vsrc/riscv32` 文件与该提交逐字一致，目录没有混入新预测器或替换模块。
身份与逐文件哈希在 `data/baseline-replay-20261009/hardware-identity.json`。

它已经有前递和 BHT16、BTB16/2 路、RAS4；不是更早的无前递/无预测实验。
原始 I-cache 为 256 B/单路/16 B 行/策略0，D-cache 为 256 B/两路/16 B 行。
用户随后要求本 replay 工作区关闭 D-cache：Makefile 的 rv32-baseline 默认及性能脚本默认现为关闭；
RTL 原文件保持不变。用 `NPC_DCACHE_ENABLE=1` 或性能脚本 `--dcache-enable 1` 可恢复。
保留其 FENCE.I、精确异常和脏 victim 恢复等既有功能。

构建工具和仿真测量代码来自当前 `316d1d2`。SoC 设备与软件源从面试工作区单独复制，
包括原有子模块改动；它们不来自旧提交。这样更换的是 CPU 硬件，使用同一软件、设备模型和统计口径。
当前面试工作区的 RTL 未修改，也没有推送新分支。

## 比较条件

- ISA：RV32I；两侧使用同一份未插入 CSR 诊断代码的 MicroBench train 镜像。
- CPU：700 MHz；设备：100 MHz；模型：`device-clock-v1`。
- 计时：原生微秒 timer；被动统计同窗口退休数与 CPU 周期。
- 当前硬件：I-cache 1 KiB/4 路/32 B/策略13，弱态 BTFNT（策略2）及早期直接目标开启。
- D-cache 两侧都为 256 B/2 路/16 B 行。总收益包括缓存组织、预测及后续电路修改，不能归为单项收益。
- 700 MHz 是本次统一仿真频点。本次没有重新综合/STA，不作新的频率、面积签核声明。

旧硬件 MicroBench **test** 已完整通过，观察器开关两次运行输出、计数和架构摘要一致：
Total 4,354,861 周期、IPC 0.188625079、6.221 ms；
Scored 1,764,863 周期、IPC 0.243821192、2.519 ms。
这是新环境下实测，不使用历史旧模型 IPC 推算 train；完整 train 尚待运行。

## 启动已准备的 train

原始旧硬件（带 D-cache 的冻结模拟器；此命令不会因工作区默认关闭而改变）：

```bash
cd /home/yong/ysyx/ysyx-workbench-rv32-baseline-replay
python3 npc/scripts/run_microbench_perf.py --resume npc/result/performance/replay-train
```

当前硬件：

```bash
cd /home/yong/ysyx/ysyx-workbench-rv32-interview
python3 npc/scripts/run_microbench_perf.py --resume npc/result/performance/replay-current-train
```

分别编译时，assert 等字符串中嵌入的绝对源路径导致镜像大小与链接地址不同。
因此两侧最终统一使用旧工作区构建的同一个 train 镜像（bin、ELF、反汇编一起冻结），
并同步 manifest 的镜像哈希和地址布局。原始哈希与原因记录于
`data/baseline-replay-20261009/train-environment-check.json`。软件、SoC 和测量源哈希完全一致。

两个目录中的模拟器和 train 镜像通过 `--prepare-only` 预先冻结；启动时校验 artifact 哈希。
建议顺序运行。使用已经保存的模拟器，无需重编译。
结果在各自目录的 `report.json`；正式比较须两份都为 PASS。

```bash
cd /home/yong/ysyx/ysyx-workbench-rv32-baseline-replay
python3 npc/scripts/compare_baseline_train.py \
  npc/result/performance/replay-train \
  /home/yong/ysyx/ysyx-workbench-rv32-interview/npc/result/performance/replay-current-train \
  --output npc/result/performance/train-comparison.json
```

比较脚本检查镜像哈希、频率、设备模型、软件/SoC/测量源哈希及 Scored 退休数。
通过后分别报告 Total、Scored 的 `旧周期/新周期` 加速比。
同频时周期比就是时间比；原生 timer 秒数另外报告，宿主仿真耗时不参与。
Total 包含打印和设备轮询，退休数可以随执行节奏变化，不强制相等。

旧 RTL 恢复后暂作为独立工作区差异保留；可用 `git diff --cached` 查看。
需要再次构建时使用相同参数的 `run_microbench_perf.py --prepare-only --output ...`，
输出目录由产物脚本锁定、覆盖；每次完成会保留小型报告并清理大编译产物。

## 关闭 D-cache：2026-10-09 实测

只修改 replay 配置；当前 interview 源码和配置没有修改。关闭后普通访存走现有
uncached AXI 通路，D-cache 不实例化；没有删除缓存源码。

同一旧 RTL、256 B/单路/16 B I-cache、BHT16/BTB16两路/RAS4，
NanGate45、AREA 3、820 MHz 映射目标，统计含复位控制与缓冲的整核标准单元：

| 配置 | 面积 µm² |
| --- | ---: |
| 原始 D-cache 256 B/两路/16 B | 70010.402 |
| 关闭 D-cache | 47692.204 |

减少 22318.198 µm²，即31.8784%。这是综合映射面积，不是布局布线面积。
820 MHz复位缓冲后四类STA检查：关闭配置通过，开启配置未通过；没有扫描最高频率。

关闭配置 lint 与原生 MicroBench test 通过：CPU700 MHz、device-clock-v1，
Total 8.301 ms、IPC0.141345339；Scored4.496 ms、IPC0.136754579。
test不是train，不据此声称完整train的速度。
参数、逐文件哈希、综合报告索引在 `data/baseline-replay-20261009/dcache-ab.json`
及 `data/run-history/`。综合/仿真大产物按规则清理。

本工作区下启动新的无 D-cache train（需要重新构建，未运行）：

```bash
python3 npc/scripts/run_microbench_perf.py --scale train --cpu-mhz 700 \
  --dcache-enable 0 --output npc/result/performance/replay-no-dcache-train
```

重新综合：

```bash
NPC_HOME="$PWD/npc" python3 npc/scripts/run_synthesis.py --target sta-reset \
  --output npc/result/synthesis/dcache-ab/off NPC_CONFIG=rv32-baseline \
  NPC_DCACHE_ENABLE=0 STA_FREQUENCY_MHZ=820 'STA_SYNTH_STRATEGY=AREA 3' \
  STA_TOOL_DIR=/home/yong/ysyx/ysyx-workbench-rv32-interview/npc/result/sta/rv32-interrupt-20260906/toolflow
```

本次沿用 interview 中的复位边界约束文件（复制到 replay 的 constr 目录），
两组使用同一工具流。性能脚本新增 `dcache` manifest 字段记录实际启用状态。

2026-10-10：replay默认进一步关闭预测；当前RTL新增开关，原始68文件身份记录描述恢复时的快照。
面积分解、功能变化和新train命令见 [无预测与面积记录](RV32_REPLAY_AREA_2026-10-10.md)。
