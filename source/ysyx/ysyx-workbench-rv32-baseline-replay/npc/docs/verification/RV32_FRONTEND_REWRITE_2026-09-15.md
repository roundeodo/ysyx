# RV32 前端重写验证：2026-09-15

本次在 `d8bb7dd` 的开发工作树上重写 frontend 目录及 IFU，先确定电路结构，再按
组合运算、寄存器边界和状态机顺序组织代码。规范已写入
[编码手册](../development/NAMING_GUIDE.md)，结构见
[前端设计记录](../microarchitecture/FRONTEND_REWRITE_DESIGN_RECORD.md)。

## 最终结构

- 查询由两级改为单级：BHT/BTB/RAS 并行组合读取，预测选择后只保存完整响应。
- BTB 移除查询 set 快照、训练 set 快照与待写事务；共享解析事件寄存后直接同步写表。
- RAS 移除栈顶副本；地址数组、指针、数量和已解析操作保留。
- I-cache 移除 blocking 协议下不可达的 refill hit 状态及 miss 进度输出。
  同步 tag/data 读、单 miss 上下文、反压响应、错误累计和唯一响应历史保留。
- AXI refill 在 AR 握手后只递增返回 byte lane 的低位，避免无用途的整地址加法。
- IFU 明确区分功能预测载荷和仅供 SVA 的 tag/epoch 验证状态。
- fetch buffer、miss unit、invalidate 与 AXI 状态机按输出、下一值、时序更新组织。

没有取消必要的同步存储读和在途事务状态，也没有增加 OoO、推测 RAS 或非阻塞 cache。

## 功能证据

| 检查 | 结果与覆盖 |
| --- | --- |
| RV32 全核 lint | 通过；没有新增 LATCH、UNOPTFLAT 或 MULTIDRIVEN 警告 |
| 预测器独立模型 | 5 组参数、60,000 周期通过；覆盖饱和计数、同 set 连续训练、四种预测类型、RAS 满/空/环绕、反压、flush、invalidate 和中途复位 |
| 真实 IFU + 预测器 | 100 条已训练跳转交付通过；目标请求间隔为 2 拍，即 1 个空拍，旧两级实现为 3 拍间隔 |
| 流水线定向回归 | 通过，含 fetch FIFO、前递、串行化、恢复与预测响应反压 |
| I-cache + AXI | RV32 一路/16 B line：13 个检查通过；两路/4 B line：11 个检查通过；覆盖 hit、替换、uncached、不可执行地址、回填前/中/后错误、响应反压和 invalidate |
| 64-bit AXI 辅助检查 | 两路/16 B line 的 cache + adapter 定向测试通过，验证 byte lane；这是模块兼容性检查，不是 RV64 整核或性能结果 |
| 中断回归 | 3 次汇编系统测试、2 次 AM 系统测试、3 项 RTL 单元测试通过 |
| RV32 CPU DiffTest | 当前目录实际存在的 35 项 CPU 测试全部 PASS，35 次 GOOD TRAP，使用 RV32 NEMU reference |
| MicroBench test | 750 MHz 和 700 MHz 下均十项通过，GOOD TRAP，原生 timer 与被动周期/退休观察一致 |

`test-predictor-equivalence` 现在回放旧版拆分对应的两个冻结提交，日志明确标注 historical。
当前实现查询延迟已经变化，使用独立模型验证，不能声称与旧版逐周期等价。

## 同频 MicroBench 比较

相同 RV32 baseline，I-cache 256 B/1 way/16 B line，D-cache 256 B/2 ways/16 B line，
BHT 16、BTB 16 项两路、RAS 4。CPU 配置 750 MHz，设备模型 100 MHz，CLINT mtime 1 MHz。
750 MHz 用于 RTL 同频比较，两版的最终映射网表都不能据此声称通过 750 MHz 时序。

| 窗口/指标 | 重写前 | 重写后 |
| --- | ---: | ---: |
| Total 周期 | 4,828,640 | 4,706,864 |
| Total 退休数 | 763,521 | 763,521 |
| Total IPC | 0.158123405 | 0.162214375 |
| Total 原生时间 | 0.006438 s | 0.006276 s |
| Scored 周期之和 | 2,168,036 | 2,115,877 |
| Scored 退休数之和 | 430,313 | 430,313 |
| Scored IPC | 0.198480560 | 0.203373353 |
| Scored 原生时间之和 | 0.002891 s | 0.002824 s |

Total 周期减少 2.52%，IPC 提高 2.59%；Scored 周期减少 2.41%，IPC 提高 2.47%。
Scored 是十个独立窗口求和，timer 的微秒量化误差也逐窗口累积，不要求与总周期除频率逐位相等。
原生定时器读取沿仍由被动观察器配对，工作负载没有加入 CSR 采样指令。

全程 PMU 中 EX corrections 从 50,204 增至 52,299；减少级数并不保证预测准确率提高。
这些 PMU 计数包含启动和退出，不属于上表 Total/Scored 窗口，不能直接混入窗口 IPC。
本轮同时改变查询和训练结构，收益是整个改动的结果，不声称每一项单独贡献多少周期。

## 面积与时序

两版都用 820 MHz 综合目标和 `DELAY 0` 策略，随后对同一缓冲网表降频做 STA。
边界为 RV32 pure core + reset controller，NanGate45 typical，Yosys/Slang + iEDA/iSTA；
不含 SoC/CLINT，不含布局布线寄生，时钟按该流程的 ideal clock 条件处理。

| 指标 | 重写前 | 重写后 |
| --- | ---: | ---: |
| 映射单元面积 | 76,480.320 μm² | 73,030.034 μm² |
| DFF 数量 | 8,869 | 8,410 |
| 数据锁存器数量 | 2,048 | 2,048 |
| 估算 Fmax | 742.966 MHz | 707.409 MHz |
| 本次通过的 STA 频率 | 730 MHz | 700 MHz |
| 对应 setup slack | +0.023 ns | +0.014 ns |

面积减少 4.51%，DFF 减少 459 个。估算 Fmax 降低 4.79%，所以不能把同频 IPC 提升
直接等同于通过时序后的执行时间改善。新网表 820 MHz setup slack 为 −0.195 ns。
700 MHz 检查：setup +0.014 ns、hold +0.057 ns、门控 setup +0.115 ns、门控 hold +0.091 ns。
当前最差数据路径终点仍为 `execute_packet[72]`，不能把全核最差延迟直接当成预测查询延迟。

700 MHz 原生 MicroBench test 十项 PASS、GOOD TRAP：

| 窗口 | 周期 | 退休指令 | IPC | 原生 timer 时间 |
| --- | ---: | ---: | ---: | ---: |
| Total | 4,498,243 | 763,521 | 0.169737606 | 0.006426 s |
| Scored | 2,033,454 | 430,313 | 0.211616786 | 0.002904 s |

该结果使用与本次 STA 通过配置一致的 700 MHz；与 750 MHz 的 IPC 不直接作结构收益比较，
因为 CPU/设备频率比例也变了。旧版没有对应的 730 MHz 原生短测，不能用本表声称在两版
各自最高可用频率下已经证明更快。本轮没有运行 train，不外推 train 时间。
性能脚本默认频率仍是 820 MHz，复测本版本应显式传入 `--cpu-mhz 700`。

## 复现与证据位置

工作树根目录设置环境，所有 make 都关闭旧自动提交钩子：

```bash
export NPC_HOME="$PWD/npc"
export AM_HOME="$PWD/abstract-machine"
export NEMU_HOME="$PWD/nemu"
make -C npc git_commit= NPC_CONFIG=rv32-baseline lint-npc test-pipeline test-predictor test-fetch test-icache
make -C npc git_commit= NPC_CONFIG=rv32-baseline test-timer-interrupt
make -C npc git_commit= NPC_CONFIG=rv32-baseline sta-reset \
  STA_FREQUENCY_MHZ=820 STA_SYNTH_STRATEGY='DELAY 0' \
  STA_TOOL_DIR="$PWD/npc/result/sta/rv32-interrupt-20260906/toolflow" \
  STA_OUTPUT_ROOT="$PWD/npc/result/performance/frontend-rewrite-20260915/sta"
python3 npc/scripts/run_microbench_perf.py --scale test --cpu-mhz 700
```

证据根目录：`npc/result/performance/frontend-rewrite-20260915/`。
保留修改前源码归档、工作区补丁、当前源码哈希、独立模型日志、DiffTest/中断日志、
各频率性能报告及原生采样、综合统计、未缓冲/缓冲网表与完整 STA。

- [同频数据对比](../../result/performance/frontend-rewrite-20260915/comparison.json)
- [750 MHz 原生报告](../../result/performance/frontend-rewrite-20260915/microbench-test-750/report.json)
- [700 MHz 时序报告](../../result/performance/frontend-rewrite-20260915/sta/riscv32_core_reset_boundary-700MHz-buffered/riscv32_core_reset_boundary.rpt)

- [700 MHz 原生报告](../../result/performance/frontend-rewrite-20260915/microbench-test-700/report.json)

## 2026-09-16：可读性复查

复查前，frontend 目录内 11 个模块及 IFU 的 SHA256 全部与上述测量归档一致。
随后仅调整排版和普通注释：整理条件赋值、case 分支、短函数调用、长条件续行与列式对齐；
修正单级预测后的 IFU 注释、同步阵列读地址来源和 AXI RLAST 来源说明。
编码手册新增人工可读性验收，明确格式化工具不能替代人工阅读。

对这 12 个文件使用 Verible 解析并比较完整词法单元序列，忽略位置与普通注释，全部一致；
其中 10 个文件的文本发生变化。RV32 baseline 全核 lint 重新通过，无 LATCH、UNOPTFLAT
或 MULTIDRIVEN 警告；`git diff --check` 通过。本次没有重新运行综合、DiffTest 或 MicroBench，
上文数据来自 9 月 15 日的功能版本，当前版本与它的逻辑对应关系由词法比较确认。
原测量哈希保留，不将新文本哈希写入旧测量记录。

本次修改前后源码归档、逐文件哈希、比较结果与 lint 日志保存在
`npc/result/performance/frontend-readability-20260916/`，见
[可读性复查结果](../../result/performance/frontend-readability-20260916/validation.json)。

同日进一步按电路归属移动 IFU 的队列/返回逻辑，以及 I-cache 的元数据写口选择。
Verible 语法树比较确认模块头、每个完整声明和过程块内容不变，仅模块内排列及注释变化。
重新运行 `rv32-baseline` 的 `lint-npc test-fetch test-icache`：lint 通过，IFU 100 次跳转
交付通过，I-cache 13 项检查通过；本次不重跑综合和工作负载。当前模块说明已精简，
旧 I-cache 说明归档。对应源码哈希、语法树比较和回归日志见
[源码顺序复查](../../result/performance/frontend-structure-docs-20260916/validation.json)。
