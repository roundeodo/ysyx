# 乘法模块职责与700 MHz验证

流水配置已使用明确的`riscv32_mul`乘法器和`riscv32_div`除法器。
乘法器只保存和计算部分积、压缩结果与64位积；EXU保存指令身份和有效位，管理
顺序完成、前递与恢复。原`riscv32_execute_pipe`已从有效源码和构建清单移除，
旧源码保存在实验快照。`rv32im-balanced`保留原迭代实现作为稳定对照。

保留配置`rv32im-pipelined`已通过700 MHz整核STA，默认频率同步改为700。
实际电路说明见[乘法设计](../microarchitecture/MUL_PIPELINE_DESIGN.md)。
本次属于数字IC流程中的RTL前端优化，具体修改CPU的EXU接收控制；
没有修改CPU取指/预测/I-cache前端的RTL。综合和STA沿用原流程，
没有修改综合策略、I/O约束、工艺库、缓存参数或存储延迟模型，也没有新增流水拍。
新旧700 MHz的SDC逐字节一致，哈希写入机器记录。

## 问题、改动与控制约束

上一版700 MHz的长路径从AXI写响应经过D-cache和LSU完成、执行许可、执行流水接收条件、
ID/EX ready，再到前端命中握手与I-cache的RRPV更新/时钟门控。最差setup余量为
数据−14 ps、门控−21 ps；该路径未经过乘法部分积或最终加法器。

旧的执行流水把`issue_allowed`先并入下游ready，再串过两级空槽判断，最后返回ID/EX。
保留改动让外部ready只表示资源容量：空槽或下游能够接收。实际入队、出队和结果valid
仍由原issue许可门控，LSU副作用门控不变。

当issue许可为真时，新旧接收条件相同；许可为假时没有输入握手。
整核在progress为假时保持ID/EX；progress为真但issue为假时必有恢复，ID/EX被flush清空。
因此不能把资源ready单独当作发射成功，也不能删除原progress或flush控制。
内部槽位推进和乘法两级写使能保持原条件，普通指令空流水直通与乘零快捷路径保留。


令`space_available`表示两个内部槽至少有一个为空，`downstream_ready`表示原EX结果级可接收。
外部接收条件的改写为：

```text
old_ready = bypass ? (downstream_ready && issue_allowed)
                   : (space_available || (downstream_ready && issue_allowed))
new_ready = bypass ? downstream_ready : (space_available || downstream_ready)
accept    = valid && issue_allowed && ready
```

对任何占用状态，`issue_allowed && old_ready == issue_allowed && new_ready`。
这说明保持发射许可时，改写不会增加或丢失有效输入握手。该结论依赖前述ID/EX保持/恢复约束，
不能把它泛化为任意valid/ready接口都可以忽略许可。
时序上的作用是让空槽、下游容量和发射许可并行到达最终选择，避免晚到的许可先穿过内部
ready传播再返回ID/EX。具体收益由综合后映射确认，不按RTL行数或逻辑运算符数量估算。

优化后的最差数据路径起点变为AXI写响应码的一位（端口bit 43），仍经过LSU/执行控制到
I-cache RRPV。原起点为写响应有效位（bit 41）；新旧最差路径并非完全相同的门链，
因此不把两条路径的延迟差直接当作某一个门级改动的独立收益。

## 面积与时序

沿用NanGate45 typ、AREA3、820 MHz映射目标、原复位树和I/O约束；iEDA检查数据及
门控时钟的setup/hold。820 MHz是映射目标，合法运行频点单独通过STA确认。
数值属于综合后单工艺角估计，未做布局布线或硅上测量。

| 版本 | 面积 / μm² | 全组通过 / MHz | 上邻失败 / MHz |
| --- | ---: | ---: | ---: |
| 上一版流水 | 116,958.604 | 680 | 700 |
| 仅重划模块职责 | 116,899.818 | 640 | 660 |
| 模块拆分加ready解耦，保留 | **117,461.078** | **700** | **720** |

仅拆模块的版本重新映射后时序退化，不能把文件拆分本身当成时序优化。
保留版本相对上一版流水面积增加0.43%；相对仅拆分版增加0.48%。
三版均为9,262个DFF、8,192个数据latch、551个clock gate，没有增加流水级或队列项。

700 MHz最差余量：数据setup +0.006 ns、门控setup +0.005 ns、数据hold +0.060 ns、
门控hold +0.097 ns。720 MHz数据与门控setup均为−0.027 ns，仍不作为可用频点。
700 MHz余量较小，不能将本次结果外推到其他工艺角或布局布线后。

## 验证和复现

两个候选均通过15,104个混合向量的算术、连续接收、反压、issue暂停、flush和错误taken
测试；接收14,647、交付13,988、总计114,784测试周期，与上一版相同。
取消计数包含尚未接收的撤销输入，不应拿它与已接收/已交付数量直接作守恒相减。

最终700 MHz配置的精确异常40/40、FENCE.I/非分支恢复/缓存错误恢复100/100、
CLINT/AM/除法及在途乘法中断、延迟0与83两组恢复均通过，保留原SVA和错误测试。
当前整核NEMU DiffTest的2,803个算术/别名/RAW/访存用例通过；连续乘法混合程序仍为
2,528周期/2,370退休，精确异常自检仍为119周期/31退休。

最终700 MHz的MicroBench test观察器开/关对照通过。同一RV32IM镜像与此前700 MHz
迭代版的Total和Scored周期、退休数、定时器结果完全相同：

| 窗口 | 周期 | 退休指令 | IPC | 原生定时器时间 |
| --- | ---: | ---: | ---: | ---: |
| Total | 2,220,172 | 483,455 | 0.217755651 | 0.003172 s |
| Scored | 915,785 | 317,725 | 0.346942787 | 0.001309 s |

量化内核同镜像也保持不变：RV32IM为192,451周期/151,125退休，RV32I软件为
2,385,341周期/2,065,811退休。它使用standalone平坦存储模型，不与SoC时间混用。
旧迭代配置和关闭M配置各11,359个原测试向量通过。没有以取消断言、删除失败用例或
修改参考结果取得通过，也没有将独立乘法吞吐提升外推成MicroBench的应用收益。


基线为HEAD `47c852e12b9ce086b872095f59cf54fbe5a6fda6`加任务入口已有工作区修改。
只修改受影响文件，没有提交或推送。机器记录在
[data/rv32-mul-modules-700mhz-2026-09-28](data/rv32-mul-modules-700mhz-2026-09-28/README.md)。

在workbench根目录用新输出目录复现；完整构建命令保存于原始日志及机器记录。

```sh
python3 npc/scripts/verify_mul_pipeline.py \
  --simulator npc/result/mul-module-700-20260928/sim/top_sim \
  --output /tmp/rv32-mul-check --cpu-mhz 700
NPC_STA_TOOLFLOW="$PWD/npc/result/sta/rv32-interrupt-20260906/toolflow" \
  python3 npc/scripts/measure_execute_ppa.py \
  --output /tmp/rv32-mul-ppa --name separated --mul-pipeline 1
python3 npc/scripts/run_microbench_perf.py \
  --scale test --isa rv32im --mul-pipeline 1 --cpu-mhz 700 \
  --icache-bytes 1024 --icache-ways 4 --icache-line 32 --icache-policy 13 \
  --bht-entries 16 --btb-entries 16 --btb-ways 2 \
  --btb-policy 0 --direction-policy 0 --history-bits 4 --ras-entries 4 \
  --verify-observer
```

本轮不重跑完整train。手动跑train可将最后一条命令改为`--scale train`，
无需重复观察器开关对照时去掉`--verify-observer`。旧命令省略`--mul-pipeline 1`
仍使用迭代配置，不能用它验证新乘法器的吞吐。
