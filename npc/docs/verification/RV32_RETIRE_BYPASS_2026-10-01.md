# RV32 退休旁路、700 MHz 与后端作用验证

2026-10-01。恢复 ALU 结果级/MUL 的队首退休旁路，保留显式 Issue；常规地址加法通过 **700 MHz**。没有新增流水级、缓冲或等待，没有改存储模型或时序约束。完整 ROB 后端仍未在 MicroBench test 上胜过原后端，因此默认仍不开启。未提交、未推送。

## 电路与开源参照

- ALU 结果级或流水 MUL 在队首完成时可当拍退休；不在队首或 Commit 反压时，写入原 ROB 项。异常元数据与结果配对，满队列可同拍退休并分配。没有恢复冗余的 `retire_bypass` 字段。
- DIV/LSU 先写 ROB，避免返回→退休/恢复→同拍派发形成反馈；所有 FU 完成到 Issue 的前递保留。没有为了表面一致而强制 ALU/MUL 等待。
- 各 FU 独立连接 ROB，观察器才组成数组，消除了恢复旁路后新增的两类整数组虚假依赖警告；最终还有五类与基线一致的总线/uncached 组合依赖警告，未屏蔽。
- 地址计算删除手写的低 12 位分组进位/高位调整，改为基址加符号扩展位移。没有改变请求发出周期。

实际阅读 CVA6 **v5.3.0**，而不是根据项目名称推断：

| 源码 | 核对到的做法 | 本核取舍 |
| --- | --- | --- |
| [scoreboard.sv](https://github.com/openhwgroup/cva6/blob/v5.3.0/core/scoreboard.sv) 的 commit_ports / Write Back / Forwarding logic | Commit 读 `mem_q`，FU 写入 `mem_n`；当拍写回另送前递接口 | 寄存后提交本身合理；本核测得局部旁路收益，选择 ALU/MUL 旁路，不能据此声称超过 CVA6 |
| [issue_read_operands.sv](https://github.com/openhwgroup/cva6/blob/v5.3.0/core/issue_read_operands.sv) 的 issue_scoreboard / gen_check_waw_dependencies / fu_data_q | 操作数与 FU 允许条件分工，执行入口有寄存边界，并包含 WAW 阻塞规则 | 本核保留明确阶段；允许同名寄存器多个 ROB 版本，代价是最近生产者年龄选择更复杂 |
| [load_store_unit.sv](https://github.com/openhwgroup/cva6/blob/v5.3.0/core/load_store_unit.sv) 的 AGU | 常规基址加位移表达式 | 采用同类常规表达，在本核重新综合验证；不照搬其 MMU 或 LSU 流水结构 |

没有同工艺同配置运行 CVA6，因此不存在“本核整体更好”的比较结论。CVA6 的宽度、提交端口、缓存和可选特权功能不能忽略。

## 条件与 STA

起始 HEAD 为 `5493a6aec976f4f9bdc075834d3f1202b0ae16ef`，但已有未提交后端修改及历史结果删除，实际基线以哈希和快照为准，未覆盖已有工作。最终工作 RTL 与通过 STA 的源码逐字节一致，见机器记录。

RV32IM、流水乘法、ROB4/load overlap；I$ 1 KiB/4 路/32 B/策略13，D$256 B/2 路/16 B，BHT16、BTB16x2、RAS4。NanGate45、AREA 3、820 MHz 映射目标、原 SDC，检查 data/gating setup/hold；20 MHz 网格。

| 配置 | 通过全部检查的频点 | mapped cell area / μm² |
| --- | ---: | ---: |
| 历史统一完成版本 | 720 | 121906.470 |
| 恢复旁路、独立 FU 接线、原分组地址加法 | 680 | 121598.708 |
| **旁路＋常规地址加法，最终配置** | **700** | **121647.652** |
| 最终配置仅去掉 Issue 寄存边界 | 620 | 120499.862 |
| 最终地址电路，原后端 | 680 | 117244.022 |

旁路初版在 700 MHz 的地址计算→LSU/PMA→uncached AXI 输出差14 ps。最终700 MHz：data setup +20 ps、gating setup +33 ps、data hold +59 ps、gating hold +97 ps；720 MHz setup为−20/−7 ps，不通过。关键数据端点转为 PMU `minstret_low_q[31]`。未布局布线，不能当作流片频率保证。

去掉 Issue 后640 MHz门控setup为−5 ps；620 MHz四组余量为+41/+35/+60/+97 ps。此比较只移除一个寄存边界，其余源码相同。

## 三项硬件分别发挥了什么作用

**Issue：用周期换取更短的组合路径，已独立测量。**

| 原生 MicroBench test | Total 周期 | 原生 Total / ms | 原生 Scored / ms |
| --- | ---: | ---: | ---: |
| 无 Issue，500 MHz | 1762091 | 3.525 | 1.582 |
| 有 Issue，500 MHz | 1788331 | 3.576 | 1.621 |
| 无 Issue，合法620 MHz | 2057057 | 3.318 | 1.400 |
| 有 Issue，合法700 MHz | 2255497 | 3.223 | 1.347 |
| 原后端，合法680 MHz | 2171419 | 3.193 | 1.329 |

同500 MHz增加1.49% Total周期、2.48% Scored周期。按各自合法频点，Issue使Total时间减少2.88%、Scored减少3.84%，面积增加0.95%，面积×Total时间减少1.96%。这证明此处阶段划分有取舍收益，不证明“加一级总会更快”。Issue随机测试也检查连续供给时每拍推进，不插稳定态气泡。

**Scoreboard：最近生产者选择与前递真正减少等待。** 关闭前递的实验仅禁止当前 ALU 和当拍 FU 完成前递，仍保留 scoreboard 依赖检查及已完成 ROB 结果；并不是删除必要的正确性逻辑。

| standalone 程序 | 原后端 | 完整后端 | 仅去掉 Issue | 仅关闭即时前递 |
| --- | ---: | ---: | ---: | ---: |
| mixed | 6649 | 6110 | 6118 | 7647 |
| issue-context | 113 | 102 | 103 | 105 |
| multiply-burst | 1076 | 1074 | 1071 | 1464 |
| load-overlap | 623 | 530 | 527 | 843 |
| dependent | 2536 | 2394 | 2393 | 2522 |
| alu-chain | 1203 | 1203 | 1200 | 3243 |
| int8 dot/normalize（RV32IM） | 192451 | 192352 | 192091 | 308610 |

上述是同镜像整核 RTL 周期，flat memory，不能当作 SoC 时间。四组消融冻结的是原分组加法；最终常规加法下六组程序与量化 RV32IM 程序周期完全一致。原生 Issue/STA 消融均使用最终常规加法。

**ROB：独立 FU 能乱序完成、顺序退休，但当前应用收益不足。** 混合FU由6649降为6110周期（减少8.11%），load/MUL由623降为530（减少14.93%）；连续乘法只从1076降到1074，原后端已支持流水MUL。多版本同名寄存器、错误路径副作用、迟到响应与槽复用也经过验证。

量化代理内核只从192451降到192352周期（约0.05%），它不是完整神经网络。MicroBench各自合法频点下，完整后端Total时间比原后端增加 **0.90%**，面积增加 **3.76%**，面积×时间增加 **4.69%**。因此不能把三项硬件一起描述成已经提升整体应用性能，默认仍用原后端。

恢复旁路在680 MHz减少7325个Total周期、4397个Scored周期；但700 MHz旁路版本仍比历史720 MHz统一完成版本的Total时间长约0.41%。保留旁路和700 MHz遵循本轮明确要求，不隐去这个取舍。

## 验证、复现与边界

通过：ROB2/4/8各10000周期随机完成、旁路反压、满队列交接与恢复；scoreboard2/4/8最近生产者参考检查；Issue/FIFO各10000周期；36组后端恢复；整核六组定向程序、乘除法、精确异常、非分支错误taken、FENCE.I/clean失败/dirty-victim恢复、中断、量化内核、原生MicroBench test。CSR专项受NEMU的mscratch支持限制使用程序自检，其余定向程序用DiffTest。没有修改参考答案或关闭断言。

本轮没有跑完整train，也没有完成train的逐窗口停顿归因。顺序发射、单在途LSU仍限制重叠；完整ROB的负结果不能单靠增容解释，更不能因定向测试有效就宣称应用已受益。

```sh
python3 npc/scripts/measure_backend_features.py --output npc/result/backend-features-recheck --cpu-mhz 700
python3 npc/scripts/test_backend_rob.py --output npc/result/bypass-rob-recheck
python3 npc/scripts/test_backend_recovery.py --output npc/result/bypass-recovery-recheck
python3 npc/scripts/measure_execute_ppa.py --output npc/result/bypass-ppa-recheck \
  --name bypass --mul-pipeline 1 --backend-rob 1 --backend-entries 4 --load-overlap 1
python3 npc/scripts/run_microbench_perf.py --scale test --isa rv32im \
  --mul-pipeline 1 --backend-rob 1 --backend-entries 4 --load-overlap 1 --cpu-mhz 700 \
  --icache-bytes 1024 --icache-ways 4 --icache-line 32 --icache-policy 13 \
  --bht-entries 16 --btb-entries 16 --btb-ways 2 --btb-policy 0 \
  --direction-policy 0 --history-bits 4 --ras-entries 4
```

手动跑train只替换`--scale train`。阶段消融仅是实验源码，不作为受支持的正式配置。
`measure_backend_native_variant.py`复用校验过的软件镜像，显式冻结变体RTL并重建对应频率模型；不会用旧周期除以新MHz。其命令记录在各原始manifest中。

配置、源码哈希、原生报告、定向结果、STA与取舍见[data/rv32-retire-bypass-2026-10-01](data/rv32-retire-bypass-2026-10-01)。原始证据索引在`summary.json`，本地根目录`npc/result/retire-bypass-20261001/`；完成的编译中间文件清理，原始大日志无损压缩，清单保留在`cleanup.json`。
