# RV32 硬件优化：面积与 MicroBench train

计时审计补充：本页旧环境 A/B 的 CLINT 为 100 MHz 口径，设备延迟比例为 3037/1024，
不能据此宣称测得了 820 MHz CPU / 100 MHz 外设的性能。820 MHz STA 通过的结论仍成立。
另行校准的测量及详细边界见 [MicroBench 计时规则](MICROBENCH_TIMING_RULES.md)。

日期：2026-09-06。工作树：`ysyx-workbench-rv32-interview`，分支 `rv32-interview`。
本轮三组有效 RTL 的完整 train 均已通过。当前保留“合并译码级 + LSU 成功完成拍发射”，
相比基线面积减少 1.06%，同环境 train IPC 提高 2.69%；不代表已达到全局最优或官方参考目标。

## 固定条件

rv32-baseline：RV32I，I-cache 256 B / 1 way / 16 B line，D-cache 256 B / 2 way /
16 B line；BHT 16 项、BTB 总计 16 项 / 2 way、RAS 4 项，ysyxSoC AXI SDRAM native burst。
三种 RTL 候选共享 SoC、缓存参数、程序镜像及工具。保留原先中断、D-cache 和时序修复。

结果：`npc/result/performance/rv32-hw-opt-20260906/`。
原始 RTL 在 `baseline/source/`，加观察模块的基线 core 在 `baseline/instrumented-core.sv`，
每个候选的 `core.sv` 是实际被工具读取的快照。`manifest.json` 保存外围源码哈希与版本。
train 镜像 `train.bin` 的 SHA-256 为
`37a82383d59b032a0354f2c6feb6012e1e583d13ebd4e9986fc7c765c9155967`。

## 已完成的测量

| 配置 | 面积 μm² | 触发器数 | 820 MHz setup slack | test 周期 | test IPC |
| --- | ---: | ---: | ---: | ---: | ---: |
| 本轮基线 | 79,002.532 | 9,363 | +0.036 ns | 1,643,700 | 0.261728 |
| 合并译码级 | 78,095.206 | 9,152 | +0.034 ns | 1,617,827 | 0.265914 |
| 合并译码级 + LSU 成功完成拍发射（当前） | 78,163.036 | 9,152 | +0.049 ns | 1,601,079 | 0.268696 |

合并译码级少 907.326 μm²（1.15%），test IPC 增加约 1.60%，两者退休指令数均为
430,203。两种配置的 setup、hold、clock-gating 检查均无负 slack；TNS 为 0。
面积包含相同的复位边界和受限扇出缓冲策略。NanGate45 typ，Yosys `DELAY 0`，iSTA，
无布局布线寄生；不能把估算频率当作流片频率，也不能与纯 core 面积混用。

展开最差路径后发现：两种配置都受到同步复位释放传播的影响。候选的终点是
`decoded_register_read_packet`，起点仍是 `core_rst_n_reg_n`。所以 2 ps 的 slack 差异
不能直接归因为正常运行中的译码/GPR 组合逻辑；完整报告保留实际路径。

## 瓶颈证据

新增 `riscv32_sim_issue_window_monitor` 在提交的成对只读 mcycle 指令之间观察。独立测试
覆盖非标记 CSR、异常、窗口开关、分类优先级与重叠。实际 test 的十个窗口逐一检查了
CSR 读回周期差与提交间周期差，全部相等，窗口总计也与程序 PMU 输出一致。

| test 窗口观察 | 基线周期 | 合并译码级周期 |
| --- | ---: | ---: |
| 实际 EXU/LSU 发射 | 430,203 | 430,203 |
| 分支纠错后直到再次发射 | 437,824 | 410,309 |
| LSU 忙导致未发射 | 407,626 | 406,802 |
| 串行化等待 | 40 | 40 |
| 指令传递空泡 | 368,007 | 370,473 |

恢复等待少 27,515 拍，总周期少 25,873 拍，和少一级流水的预期一致。D-cache miss
均为 3,763 次、dirty miss 均为 1,562 次；I-cache miss 为 16,808 → 16,669。
分类存在优先级，不是消除某因素的加速上界。RAW 分类为 0 也不表示不存在数据依赖，
可能已经被 LSU 忙等较高优先级状态覆盖。旧监视器的单指令上下文/ideal IPC 不作为依据。

## 验证与取舍

合并译码级：MicroBench test 十项通过；流水控制、特权/提交/PMU、3 组汇编中断系统、
2 组 AM 中断系统、CLINT、IRQ 控制器、IFU redirect、复位和 1,024 组 EX 结果测试通过。
尚未做本轮全核形式证明或 DiffTest。完整 train 已通过，结果见下方汇总。

继续合并寄存器读级的独立候选未通过 820 MHz STA，已恢复，详见下方失败记录。
不直接取消 `lsu_transaction_active` 对发射的约束，因为它当前保证顺序完成与精确异常。

## 复现

所有 make 必须传 `git_commit=`，并将 `NPC_HOME`、`AM_HOME` 指向本工作树。

```sh
make -C npc NPC_CONFIG=rv32-baseline git_commit= test-issue-window
python3 npc/scripts/analyze_issue_window.py <run.log> --output <result.json>
python3 npc/tests/hardware-optimization/summarize.py npc/result/performance/rv32-hw-opt-20260906
```

train 使用固定的 `train.bin`，通过保存的各个 `simulator --batch --flash <train.bin>` 执行。
基线首次由 `make perf PERF_SCALE=train` 构建镜像并运行，随后保存同一镜像与模拟器。
综合命令使用 `sta-reset STA_FREQUENCY_MHZ=820 STA_SYNTH_STRATEGY='DELAY 0'`，
`STA_TOOL_DIR` 指向 `npc/result/sta/rv32-interrupt-20260906/toolflow`，各候选使用独立
`STA_OUTPUT_ROOT`。`summary.json` 只采纳结束且成功的测量，未完成项明确标记 pending。

## 追加：继续合并 RR 的失败结果

合并译码与 RR 两级后面积为 76,795.530 μm²，820 MHz setup slack 为 −0.105 ns，
估算 Fmax 755.209 MHz。该方案不满足本轮 820 MHz 约束，未做完整功能或 train 验证，
不保留在当前工作代码。原型位于 `merge-decode-read/core.sv`。

## 追加：train 首个窗口与 LSU 完成边界实验

基线 qsort 窗口已结束：6,426,129 条指令 / 22,106,632 拍，其中 LSU 忙 11,825,192 拍
（53.49%），分支恢复 2,485,141 拍（11.24%）。D-cache miss 141,638 次，dirty miss
110,786 次。计数来自已完成窗口后对专用观察计数器的只读快照，不是完整 train 结果。
GDB 只短暂停止宿主进程并读取计数，未改变模拟器状态；宿主暂停不增加 guest 周期。
合并译码级的 qsort 窗口为 22,005,401 拍，只减少约 0.46%，再次说明 test 收益不能外推。

第三项实验允许 LSU 成功完成拍发射独立 ALU 指令。原理及异常/顺序约束见设计记录；
独立目录为 `lsu-completion-issue`。功能、STA 与完整 train 均已通过。

## 追加：LSU 完成边界候选的已完成结果

面积 78,163.036 μm²；820 MHz setup slack +0.049 ns，hold 与 clock-gating 均通过。
相比合并译码级多 67.830 μm²，但 test 周期从 1,617,827 减少到 1,601,079，IPC
从 0.265914 提升到 0.268696；相比本轮基线，面积少 1.06%，test IPC 高 2.66%。
D-cache miss/dirty miss 仍为 3,763/1,562 次。LSU 忙观察周期为 406,522，阻止发射
周期为 381,369；成功完成边界的重叠减少等待，前端空泡则抵消部分收益。

控制单元新增成功完成、EX 结果反压、pending-load RAW 和未成功完成检查；中断系统
五组及三组外围/控制单元回归通过。全核加入断言，检查 LSU 活动期间若年轻 ALU 发射，
则旧 LSU 必须已成功交付 WB，且 EX 结果级为空。该断言已编译进中断系统回归。
第三候选的固定镜像完整 train 已通过，当前源码保留该候选。

## 完整 train 结果与本轮决定

| 配置 | 周期 | 退休指令 | IPC | Scored time（旧计时） |
| --- | ---: | ---: | ---: | ---: |
| 基线 | 670,929,314 | 186,810,217 | 0.278435 | 6.709399 s |
| 合并译码 | 659,679,012 | 186,810,217 | 0.283184 | 6.596894 s |
| 合并译码 + LSU 完成拍发射 | 653,329,501 | 186,810,217 | 0.285936 | 6.533402 s |

三组均为十项 PASS、GOOD TRAP，观察窗口与程序 PMU 对齐。保留第三方案：相对基线
面积少 839.496 μm²，周期少 17,599,813；相对仅合并译码，多 67.830 μm²，周期少
6,349,511。RR 合并候选因 820 MHz 时序失败而恢复，未报告其功能或 train 通过。

另行校准 CPU 820 MHz / 设备 100 MHz 后，同一第三方案的 train 为 1,089,343,319 拍、
186,810,217 条指令、IPC 0.171489，Scored time 1.328498 s、Total time 1.953871 s。
该行改变了计时和访存模型，不能当作硬件优化加速比，也不直接与官方 4.49 s 比较。

原始数据：`result/performance/rv32-hw-opt-20260906` 下各目录 `train-o3.log`、
`train.json`、`train-o3-run.json`；汇总为 `summary.json`、`comparison.json`、
`timing-summary.json`。O3 只优化宿主生成模型的编译，固定 RISC-V 镜像未改变，
四种环境均先完成 test 全计数器一致性检查再执行完整 train。
