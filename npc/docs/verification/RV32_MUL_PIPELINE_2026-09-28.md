# RV32 乘法流水验证与取舍

此记录对应680 MHz历史版本；当前模块职责和700 MHz结果见
[后续验证](RV32_MUL_MODULES_700MHZ_2026-09-28.md)。

已实现并验证三拍乘法流水，独立乘法启动间隔一拍。命名配置为
`rv32im-pipelined`，默认 680 MHz；`rv32im-balanced` 仍是 700 MHz 迭代版。
连续独立乘法有明显收益，当前 MicroBench test 和量化内核没有周期收益，
因此不自动切换稳定默认配置。除法仍逐位迭代，未实现通用 Scoreboard/ROB。
电路原理只维护在[乘法流水说明](../microarchitecture/MUL_PIPELINE_DESIGN.md)。

## 基线和证据

任务入口 HEAD 为 `47c852e12b9ce086b872095f59cf54fbe5a6fda6`，分支
`frontend-exploration-20260921`，存在大量此前工作区修改。基线是入口源码快照，
不是裸 commit；没有清除已有研究、M 扩展、延迟模型或用户修改，也没有提交或推送。

本轮原始结果位于 `npc/result/mul-pipeline-20260928/`。可入库的小型记录在
[data/rv32-mul-pipeline-2026-09-28](data/rv32-mul-pipeline-2026-09-28/README.md)，
包括机器结果、源码哈希、回归命令及原始日志索引。综合后只有新模块的空白排版和
仿真断言覆盖调整，可综合电路与最终综合快照一致。

配置：RV32IM，I-cache 1 KiB/4路/32 B/policy 13，D-cache 256 B/2路/16 B，
BHT 16项，BTB 16项/2路/完整目标/policy 0，方向策略0，RAS 4项。
同频性能比较的两份 ELF/bin 哈希相同；没有改软件算法、缓存、预测器或访存延迟模型。

## 实现边界

乘法分成分块部分积、carry-save 压缩、最终相加三个运算拍；只有两个新增内部
寄存边界，第三拍直接进入原 EX 结果寄存器。从 EX 输入有效的运算拍开始计延迟三拍；
从第一个内部寄存器接收请求的沿算起，到结果接收沿相隔两拍。

普通结果在流水为空时直通，已有老乘法时按顺序通过同一通路；可用值直接前递。
乘零保留快捷路径。每级同时保存 PC、rd、异常和预测身份，最近的未就绪生产者
阻止错误使用更老结果。LSU 等老执行项排空，中断、异常、分支及非分支错误 taken
恢复都覆盖新增在途项。年轻除法也会被老指令恢复取消。

ID/EX 同沿另存乘法的 64 位操作数，用于隔离部分积电路的扇出，没有新增周期。
这不是未来 Scoreboard 的占位寄存器。其保留依据是整核 STA 的实测改善。
除法可与正在排空的老乘法重叠，但年轻指令不能越过除法。

## 正确性

- Python 整数参考生成 15,104 个混合向量；被 flush 撤销的指令不要求产生结果。
  包含连续 160 条独立乘法、全部 M 运算、随机反压和 issue 暂停、恢复与结果交付同拍、
  错误 taken、PC/结果 FIFO 配对；SVA 启用，通过。
- 整核 NEMU DiffTest：2,803 个算术/寄存器别名/RAW/访存用例通过。
  连续乘法与混合指令程序 DiffTest 通过；老乘法、非法指令、年轻乘法/store 的精确异常自检通过。
- 最终 680 MHz 配置：精确异常 40/40，FENCE.I/非分支恢复/缓存错误恢复 100/100，通过。
  原 clean 失败停止、dirty victim 恢复和错误目标无副作用用例保留。
- 中断回归通过：保留 CLINT、AM、除法中途 IRQ、访存、旧 epoch 用例；新增乘法
  流水在途时触发 IRQ，存储延迟0和83两组，检查先排空再接受中断及精确 mepc。
- 旧迭代配置和关闭 M 的原单元测试仍通过。
- 两个 680 MHz MicroBench test 仿真均完成观察器开/关对照，计数器没有改变执行。

独立 RTL 与系统回归使用 `--assert`。standalone 程序使用 DiffTest/软件自检，
其构建没有启用 SVA；不能把全部程序测试称为断言仿真。未重跑完整 train，未做形式证明。
原每指令类别延迟观察器只有单上下文，流水模式显示 `n/a`，也不输出它导出的 oracle
上界；原生定时器、被动退休/周期计数和缓存统计继续有效。

## 面积、时序和性能

沿用 NanGate45 typ、Slang/Yosys、AREA3、820 MHz 映射目标、原 I/O 和复位树约束。
iEDA 检查数据及门控时钟的 setup/hold；频率按20 MHz网格验证，通过点及上邻失败点均实测。
这是综合后估计，未做布局布线或硅上测量，820 MHz 不代表可运行频率。

| 配置 | 面积 / μm² | 全组通过 / MHz | 上邻失败 / MHz |
| --- | ---: | ---: | ---: |
| 原迭代版 | 106,339.086 | 700 | 720 |
| 流水初版，共用操作数驱动 | 117,230.190 | 620 | 640 |
| 保留流水版，乘法操作数隔离 | 116,958.604 | 680 | 700 |

迭代版依据见[已有时序记录](RV32IM_FRONTEND_TIMING_2026-09-28.md)。
最终流水版面积增加9.99%。680 MHz的最差余量：数据 setup +0.020 ns、门控 setup
+0.012 ns、数据 hold +0.059 ns、门控 hold +0.096 ns。700 MHz数据/门控 setup
分别 −0.014/−0.021 ns，终点是 I-cache RRPV 状态及门控，不能声称已通过700。
重复启动造成的两份未完成综合已标记无效，不用于表格。

| 同频、同镜像负载 | 迭代版周期 | 流水版周期 | 退休指令 |
| --- | ---: | ---: | ---: |
| 连续乘法及依赖/混合指令定向程序 | 6,614 | 2,528 | 2,370 |
| RV32IM 点积/归一化内核 | 192,451 | 192,451 | 151,125 |
| MicroBench test Total，680 MHz | 2,171,419 | 2,171,419 | 483,449 |
| MicroBench test Scored，680 MHz | 901,995 | 901,995 | 317,725 |

前两项为 standalone 平坦存储模型；定向程序同频加速2.616倍，按迭代700/流水680 MHz
计算为2.542倍。该程序刻意包含连续独立乘法，不能代表真实应用的普遍收益。

SoC测试继续使用 `device-clock-v1`：设备100 MHz，CLINT对软件提供1 MHz计数，
周期与退休数由被动观察器按原生计时窗口统计。680 MHz两版完全相同：
Total **0.003193 s、IPC 0.222641968**；Scored **0.001329 s、IPC 0.352246964**。
微秒量化会让短窗口的定时器时间与 cycles/frequency 略有差异。

按各自合法频点实跑：迭代700 MHz的Total/Scored为0.003172/0.001309 s，
流水680 MHz为0.003193/0.001329 s，分别慢0.66%/1.53%。设备延迟使用独立频率模型，
这些时间来自实际运行，不能将所有旧周期直接按频率缩放。之前700 MHz的流水初版
只用于功能周期对照，未通过STA，不作为合法运行成绩。

## 取舍和复现

保留可选流水版，用于连续独立乘法和后续调度实验；稳定版继续使用迭代乘法。
当前实际负载没有抵消增加的面积和退频。相关乘法链仍依赖结果可用时间，流水化
不能消除 RAW；访存等待或较稀疏的乘法也不会自然转化为吞吐收益。
未做功耗测量，不声称功耗改善。Scoreboard、允许年轻指令越过除法、流水除法均留待独立设计。

在 workbench 根目录使用新目录复现，先设置本机依赖：

```sh
export NPC_HOME="$PWD/npc"
export AM_HOME="$PWD/abstract-machine"
export NEMU_HOME="$PWD/nemu"
make -C npc git_commit= NPC_CONFIG=rv32im-pipelined \
  CAPSTONE_HOME="$PWD/../ysyx-workbench/nemu/tools/capstone/repo" \
  BUILD_DIR="$PWD/npc/result/mul-pipeline-local/sim" build-npc
python3 npc/scripts/verify_mul_pipeline.py \
  --simulator npc/result/mul-pipeline-local/sim/top_sim \
  --output npc/result/mul-pipeline-local/check --cpu-mhz 680
NPC_STA_TOOLFLOW="$PWD/npc/result/sta/rv32-interrupt-20260906/toolflow" \
  python3 npc/scripts/measure_execute_ppa.py \
  --output npc/result/mul-pipeline-local/ppa --name pipelined --mul-pipeline 1
```

使用新的性能输出目录；迭代同频对照只把 `--mul-pipeline 1` 改为0：

```sh
python3 npc/scripts/run_microbench_perf.py \
  --scale test --isa rv32im --mul-pipeline 1 --cpu-mhz 680 \
  --icache-bytes 1024 --icache-ways 4 --icache-line 32 --icache-policy 13 \
  --bht-entries 16 --btb-entries 16 --btb-ways 2 \
  --btb-policy 0 --direction-policy 0 --history-bits 4 --ras-entries 4 \
  --verify-observer
```

完整 train 可将 `--scale test` 改为 `--scale train`；无需重复观察器对照时去掉
`--verify-observer`。不传 `--mul-pipeline` 的旧命令仍使用迭代乘法。
不要传 `--btb-target-bits 0`，完整目标由省略该参数选择。
