# Cache设计空间探索

## 1. 目标

本工具实现手册所述的第一类`cachesim`：NEMU负责执行程序并输出架构动态PC序列，独立的
元数据Cache模型重放该序列。它用于低成本比较容量、Cache line大小和路数，不代替RTL
功能验证、综合、STA或完整系统性能测试。

当前流程回答三个问题：在同一条动态指令流下，不同I-cache几何参数会产生多少次需求取指
miss；在给定总线阶段延迟模型后，关键字响应时间和完整line refill占用如何变化；在同一条
动态load/store序列下，不同D-cache几何参数会产生多少miss、脏块写回和下层存储流量。它
不模拟逐周期AXI反压、错误路径取指、预取、多MSHR和miss重叠。

## 2. 文件和职责

| 文件 | 职责 |
| --- | --- |
| `tools/cachesim/cachesim.cpp` | 解析PC或数据访问trace，维护组相联LRU元数据，统计3C、AMAT、TMT、refill和脏块写回 |
| `tools/cachesim/explore.py` | 并行启动多组cachesim，排序并生成CSV |
| `tools/cachesim/tests/test_cachesim.py` | 用确定性地址序列验证冲突miss、容量miss和日志解析 |
| `nemu/configs/riscv32-cachesim_defconfig` | 构建可执行、启用紧凑PC trace的RV32 NEMU |
| `nemu/configs/riscv64-cachesim_defconfig` | 构建可执行、启用紧凑PC trace的RV64 NEMU |

`cachesim`中的被测Cache和全相联Shadow Cache都使用精确LRU。Shadow Cache容量和行大小与
被测Cache相同，但只有一个set。每次真实Cache miss按以下规则分类：

1. 该block从未出现过：compulsory miss；
2. 该block在全相联Shadow Cache中命中：conflict miss；
3. 该block在Shadow Cache中也未命中：capacity miss。

Shadow Cache使用哈希表和LRU链表，查询与更新为均摊O(1)，不能对所有line逐项扫描。

## 3. 固定工作流

以下命令均在`ysyx-workbench/npc`执行。

### 3.1 构建和局部验证

```sh
make cachesim-test
```

### 3.2 用NEMU生成动态PC序列

默认运行已经由NPC平台构建的RV32I `bubble-sort`镜像：

```sh
make cachesim-trace
```

也可以指定任意能被当前NEMU正确执行的镜像：

```sh
make cachesim-trace \
  CACHE_TRACE_IMAGE=../am-kernels/tests/cpu-tests/build/crc32-riscv32-npc.bin \
  CACHE_TRACE_FILE=result/cache/riscv32_crc32_nemu_pc_trace.bin
```

紧凑trace只记录取指PC，并用`起始PC + 指令数 + 固定步长`描述一段连续序列。文件头保存
PC宽度、总指令数和记录数；它比逐条文本itrace小得多，`cachesim`也仍能兼容旧文本格式。

该目标会将NEMU活动配置切换为`riscv32-cachesim_defconfig`。后续运行DiffTest前，使用
`make nemu-ref-rv32`或`make nemu-ref-rv64`重新生成对应reference。

### 3.3 评估单组参数

```sh
make cachesim-run \
  CACHE_TRACE_FILE=result/cache/riscv32_crc32_nemu_pc_trace.bin \
  CACHE_CAPACITY_BYTES=8192 \
  CACHE_LINE_BYTES=32 \
  CACHE_WAYS=2
```

### 3.4 扫描参数组合

```sh
make cachesim-explore \
  CACHE_TRACE_FILE=result/cache/riscv32_crc32_nemu_pc_trace.bin \
  CACHE_SCAN_CAPACITIES=4096,8192,16384,32768 \
  CACHE_SCAN_LINE_SIZES=16,32,64 \
  CACHE_SCAN_WAYS=1,2,4 \
  CACHE_SCAN_JOBS=4 \
  CACHE_SCAN_OUTPUT=result/cache/cachesim_riscv32_crc32_exploration.csv
```

默认使用历史`fixed`模型和4B refill beat，从而使原有`make cachesim-explore`命令继续复现
旧结果。需要研究传输组织时，必须显式运行下面的目标，在同一份trace和同一组Cache几何上
分别重算独立读事务与AXI4 INCR burst：

```sh
make cachesim-explore-transport \
  CACHE_TRACE_ARCH=riscv64-nemu \
  CACHE_TRACE_FILE=../am-kernels/benchmarks/microbench/build/nemu-log.txt
```

总线阶段参数为：AR握手`a`、memory command阶段`b`、首个数据返回`c`和每个R beat
间隔`d`。默认四项均为1周期，只是用于观察结构差异的归一化模型，可以通过
`CACHE_READ_ADDRESS_CYCLES`、`CACHE_MEMORY_COMMAND_CYCLES`、
`CACHE_FIRST_DATA_CYCLES`和`CACHE_RESPONSE_BEAT_CYCLES`修改。

对一条line中的`N`个beat，以及在第`K`个beat出现的critical word：

```text
independent critical penalty = K * (a + b + c + d)
independent complete refill   = N * (a + b + c + d)
burst critical penalty       = a + b + c + K * d
burst complete refill        = a + b + c + N * d
```

`K`不是人为假设。cachesim在每次miss时由PC的line内偏移计算，并在整条trace上取平均。
当前RTL按line base开始升序burst，因此该计算与实际critical-word early restart顺序一致。

三种模型的绝对AMAT和TMT不能互相比较：

- `fixed`用于复现历史基线，缺失代价由外部直接给定；
- `independent`和`burst`用于控制变量实验，只能在相同`a/b/c/d`参数下互相比较；
- RTL实测值只允许与相同仿真顶层、存储模型、workload和统计窗口下的其他RTL结果比较。

因此，归一化`a=b=c=d=1`得到的数值不能与历史`284.142 cycles`或standalone RTL的实测
周期直接计算提升比例。

得到RTL实测数据后，使用`fixed`模型分别回灌关键字可见代价和完整refill代价：

```sh
make cachesim-explore \
  CACHE_REFILL_MODEL=fixed \
  CACHE_CRITICAL_RESPONSE_PENALTY_BY_LINE_SIZE=16=4.178,32=4.625,64=5.964 \
  CACHE_COMPLETE_REFILL_PENALTY_BY_LINE_SIZE=16=6.043,32=10.017,64=18.006
```

### 3.5 使用RV64 MicroBench长trace

CPU-test的代码工作集太小，只适合验证工具。正式扫描前先构建带itrace的RV64 NEMU，再运行
MicroBench `test`：

```sh
make -C ../nemu riscv64-cachesim_defconfig
make -C ../nemu
make -C ../am-kernels/benchmarks/microbench \
  ARCH=riscv64-nemu run mainargs=test
```

MicroBench的NEMU日志可以直接作为cachesim输入：

```sh
make cachesim-explore \
  CACHE_TRACE_ARCH=riscv64-nemu \
  CACHE_TRACE_FILE=../am-kernels/benchmarks/microbench/build/nemu-log.txt \
  CACHE_SCAN_CAPACITIES=1024,2048,4096,8192,16384,32768 \
  CACHE_SCAN_LINE_SIZES=16,32,64 \
  CACHE_SCAN_WAYS=1,2,4 \
  CACHE_SCAN_OUTPUT=result/cache/cachesim_riscv64_burst_exploration.csv
```

当前MicroBench由`rv64g`工具链构建，会生成M扩展指令。NEMU已经实现基础RV32M/RV64M和
RV64的`MULW/DIVW/DIVUW/REMW/REMUW`，并用独立边界测试覆盖除零、最小负数除以`-1`、
高位乘法和W类符号扩展。

## 4. 当前流程验证结果

### 4.1 CPU-test工具链验证

2026-08-21使用RV32I `crc32`得到13277条动态指令。当前8KiB、2-way、32B line模型得到：

- 10次miss，全部为compulsory miss；
- Hit Rate为99.9246818%；
- 使用284.142 cycles常数估算，AMAT为2.214010695 cycles；
- TMT为2841.42 cycles。

该程序只访问10条32B指令Cache line，远小于4KiB，因此容量和路数扫描结果相同。这个结果
只证明trace生成、解析、3C分类和参数扫描链路工作正常，不能用于选择最终Cache容量或路数。

### 4.2 RV64 MicroBench test探索

2026-08-21运行RV64 MicroBench `test`，全部10个子测试通过。完整程序执行723827条动态
指令，其中PMU标记的benchmark测量窗口为276790条退休指令。文本trace为33.9MB，包含
启动、benchmark、结果验证和输出路径。

32B line的部分结果如下：

| 容量 | 路数 | Miss | Compulsory | Capacity | Conflict | Hit Rate |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1KiB | 1 | 1674 | 555 | 748 | 371 | 99.7687% |
| 1KiB | 2 | 1507 | 555 | 781 | 171 | 99.7918% |
| 1KiB | 4 | 1421 | 555 | 812 | 54 | 99.8037% |
| 4KiB | 1 | 846 | 555 | 54 | 237 | 99.8831% |
| 4KiB | 2 | 748 | 555 | 56 | 137 | 99.8967% |
| 8KiB | 1 | 686 | 555 | 6 | 125 | 99.9052% |
| 8KiB | 2 | 590 | 555 | 10 | 25 | 99.9185% |
| 8KiB | 4 | 572 | 555 | 10 | 7 | 99.9210% |
| 32KiB | 任意 | 555 | 555 | 0 | 0 | 99.9233% |

这组数据已经能观察容量和相联度的作用：增大路数主要减少conflict miss，增大容量同时减少
capacity和conflict miss。早期扫描曾把32B line的一个实测常数套到所有line大小；该结果只
用于验证工具链，已经由下面的分line实测校准结果取代。

同为8KiB、2-way时，16/32/64B line分别产生1135/590/316次miss，但refill流量分别为
18160/18880/20224B。更大的line减少miss却增加传输流量；在获得各line大小的真实refill
代价前，不能仅按miss次数排序。

### 4.3 更大line与burst传输探索

本节包含三个相互独立的受控实验，不能跨实验比较绝对周期：

1. `fixed`回归只验证新版cachesim没有改变旧模型；
2. 归一化传输模型只比较独立事务和burst的结构差异；
3. standalone RTL实验只比较同一仿真存储模型下的16/32/64B line。

首先使用相同MicroBench trace、相同54组Cache几何和相同`284.142 cycles`固定代价重跑旧
模型。新版`fixed`输出与旧版`cachesim_riscv64_microbench_test_exploration.csv`的miss分类、
命中率、AMAT、TMT和refill流量逐项一致，差异数为0。8KiB、2-way结果如下：

| Line | Miss | 固定代价TMT | 固定代价AMAT |
| ---: | ---: | ---: | ---: |
| 16B | 1135 | 322501.170 | 2.445550 |
| 32B | 590 | 167643.780 | 2.231608 |
| 64B | 316 | 89788.872 | 2.124047 |

这张表只能表示“所有line拥有相同缺失代价”时，减少miss次数带来的理论趋势，不能用来判断
更大line的真实收益。

RTL现在通过`NPC_ICACHE_LINE_BYTES`选择line大小。`ICACHE_SET_COUNT`、tag/set/offset宽度、
data array深度、refill word计数和AXI4 ARLEN均从该值派生。16/32/64B使用独立构建目录，
避免改变宏后误用旧Verilator产物：

```sh
make lint-npc PROJECT=riscv32 NPC_CONFIG=rv64-sequential NPC_ICACHE_LINE_BYTES=64
make sim-npc PROJECT=riscv32 NPC_CONFIG=rv64-sequential \
  NPC_ICACHE_LINE_BYTES=64 IMG=/path/to/microbench-riscv64-npc.bin
```

在8KiB、2-way、4B beat下，NEMU MicroBench trace得到：

| Line | Miss | Hit Rate | 平均critical beat位置 | Refill流量 |
| ---: | ---: | ---: | ---: | ---: |
| 16B | 1135 | 99.8432% | 1.155 | 18160B |
| 32B | 590 | 99.9185% | 1.583 | 18880B |
| 64B | 316 | 99.9563% | 3.057 | 20224B |

归一化`a=b=c=d=1`时，两种传输组织的结果为：

| Line | 独立事务critical TMT | 独立事务整行占用 | Burst critical TMT | Burst整行占用 |
| ---: | ---: | ---: | ---: | ---: |
| 16B | 5244 | 18160 | 4716 | 7945 |
| 32B | 3736 | 18880 | 2704 | 6490 |
| 64B | 3864 | 20224 | 1914 | 6004 |

独立事务会为每个4B word重复支付AR和首数据延迟，64B line虽然miss更少，但critical TMT
反而略差于32B。burst只支付一次请求建立开销，64B line在这条trace上同时得到最低
critical TMT和最低完整refill占用。这正是手册要求比较的优化点。这里的数值单位来自归一化
阶段参数，只能在本表内部比较，不能与上面的fixed表或下面的RTL周期相减。

三种line大小随后在RV64 standalone RTL上运行同一个MicroBench `test`，10项全部通过：

| Line | RTL Miss | 实测critical penalty | 实测完整refill | 测量窗口周期 | 测量窗口IPC |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 16B | 1213 | 4.178 | 6.043 | 1432513 | 0.286341 |
| 32B | 634 | 4.625 | 10.017 | 1431536 | 0.286536 |
| 64B | 337 | 5.964 | 18.006 | 1431192 | 0.286605 |

NPC和NEMU的启动代码、平台代码及取指口径不同，所以RTL Miss不能与cachesim Miss逐项相等；
可比较的是line大小变化的趋势。把三种RTL critical penalty回灌NEMU trace后，8KiB、2-way
的critical TMT分别为4742.030、2728.750和1884.624周期。64B在本次测试中最好，但相对
32B只让MicroBench测量窗口减少344周期，IPC提升约0.024%。该收益不足以直接冻结64B：
下一步还必须比较SRAM组织、综合面积、命中路径时序，以及更接近目标AI软件的trace。

上述RTL结果来自相同的standalone顶层和`riscv32_axi4_sim_mem`，所以三种line之间可直接
比较；它们不能与早期高延迟环境得到的`284.142 cycles`直接比较。后续若要评估真实SoC
收益，必须在同一个ysyxSoC存储路径下重新测量32B基线和其他候选line。

### 4.1 用RTL自动校准cachesim缺失代价

现在使用下面的目标在完全相同的RV32 ysyxSoC、SDRAM、AXI delay和原生BL8环境中，分别
编译16B、32B和64B I-cache并运行MicroBench：

```sh
cd /home/yong/ysyx/ysyx-workbench/npc
make icache-calibrate-penalty ICACHE_CALIBRATION_SCALE=test
```

短规模用于检查流程，正式记录使用`train`：

```sh
make icache-calibrate-penalty \
  ICACHE_CALIBRATION_SCALE=train \
  ICACHE_CALIBRATION_LINE_SIZES=8,16,32,64
```

脚本实时转发仿真输出；每完成一种line大小，就立即更新
`result/cache/rtl_icache_penalty_rv32_sdram_bl8_<scale>.csv`，并把完整终端输出保存到
`result/cache/calibration_logs/`。因此长时间仿真即使中途停止，已经完成的项目仍然保留。

校准表给cachesim提供两个不同的周期量：

- `average_miss_penalty_cycles`是关键字交付给IFU的延迟减去正常hit延迟，用于计算AMAT和
  critical TMT；
- `average_complete_refill_latency_cycles`是从miss开始到整条cacheline全部写入array的时间，
  用于评估miss unit、AXI和下层存储器被占用的时间。

生成校准表后运行：

```sh
make cachesim-explore-calibrated ICACHE_CALIBRATION_SCALE=train
```

该目标读取CSV中每种line大小各自的实测周期，再对NEMU PC trace扫描容量、line大小和路数。
CSV已经包含当前AXI、延迟模块、SDRAM控制器和refill微架构的综合效果，因此这里使用
`fixed`模型；不能再叠加`independent`或`burst`理想时间公式，否则会重复计算传输开销。

校准脚本同时保存MicroBench PMU测量窗口的cycle、retired instruction和IPC，用来确认三次
运行执行了同一工作量。I-cache lookup/hit/miss计数覆盖完整仿真，而PMU窗口只覆盖
MicroBench计分区间，两者的统计边界不同，不能拿lookup数直接除以PMU周期。

## 5. 设计结论的证据要求

正式参数选择至少需要：

1. 能代表目标AI软件栈的长时间动态PC序列；
2. 每种line大小在RTL/SoC中测得的critical-response和完整refill代价；
3. 候选方案对应的SRAM面积、命中路径时序和功耗；
4. 在RTL PMU上复核Hit/Miss、AMAT、前端阻塞周期和IPC。

当前NEMU紧凑PC trace不包含redirect后的过期取指。它适合需求取指设计空间探索；未来
验证分支预测、预取和错误路径污染时，应另外记录NPC I-cache请求握手trace，不能混用两种
统计口径。

## 6. 历史RV32E口径面积探索

本节记录早期64B容量、direct-mapped、8B line课程候选，不再代表当前RV32I默认配置。
所有tag/data存储均映射为Nangate45标准单元，没有通过黑盒或综合排除隐藏面积。300MHz
约束下的历史实测结果为：

| line | 核面积 | WNS | 最高频率估计 | 结论 |
| ---: | ---: | ---: | ---: | --- |
| 4B | 23988.146 um^2 | +0.653 ns | 373.182 MHz | 超过23000 um^2，淘汰 |
| 8B | 22708.952 um^2 | +0.578 ns | 363.022 MHz | 满足当时面积约束，历史候选 |
| 16B | 22474.340 um^2 | +0.766 ns | 389.599 MHz | 面积满足，blocking refill较慢 |
| 32B | 21808.276 um^2 | +0.855 ns | 403.614 MHz | 面积满足，blocking refill最慢 |

当前64B总容量非常小，改变line大小也会同时改变set数量。因此该表不能解释为“line越大面积
必然越小”，而是这几个具体参数组合经过同一工具链综合后的联合结果。

## 7. MicroBench train快速探索

使用NEMU执行MicroBench `train`得到63102503条需求取指PC，紧凑trace保存于
`result/cache/riscv32_microbench_train_pc_trace.bin`。该trace只反映已提交路径，适合比较
容量、line和路数引起的需求miss，不包含redirect后的错误路径请求。

64B、direct-mapped的几何扫描结果为：

| line | Miss | Hit Rate |
| ---: | ---: | ---: |
| 4B | 28180869 | 55.3411% |
| 8B | 15977866 | 74.6795% |
| 16B | 9246162 | 85.3474% |
| 32B | 8105770 | 87.1546% |
| 64B | 9708149 | 84.6153% |

64B line只有一个set，冲突和容量效应反而使miss回升。扩大总容量比只扩大line更有效：例如
1KiB/8B/1-way降到667497次miss，8KiB/8B/4-way只剩2461次miss；但当前array使用标准单元，
128B/16B已经达到25406.458 um^2，无法满足23000 um^2课程面积约束。

## 8. Blocking TMT

当前I-cache只有一个miss表项。critical word返回后可以让当前取指提前继续，但miss unit仍要
等待整行refill完成，期间不能接收下一条lookup。因此当前RTL的快速排序指标不能只使用
`critical TMT = miss count * critical penalty`，还必须计算：

```text
blocking TMT = miss count * complete refill latency
```

同一PSRAM环境的RTL标定中，8B、16B、32B line的miss critical penalty分别为
162.405、236.170、489.787周期，完整refill分别为286.283、565.662、1121.856周期。
代入同一份train trace：

| line | Critical TMT | Blocking TMT |
| ---: | ---: | ---: |
| 8B | 2.595e9 cycles | 4.574e9 cycles |
| 16B | 2.184e9 cycles | 5.230e9 cycles |
| 32B | 3.970e9 cycles | 9.094e9 cycles |

16B仅看critical TMT时优于8B，但完整refill占用使blocking TMT高14.3%。32B虽将miss减少
49.3%，完整refill延迟却约为8B的3.92倍，最终blocking TMT约为2倍。因此课程配置继续使用
8B line。完整结果保存在
`result/cache/riscv32_microbench_train_psram_measured_8B_16B_32B.csv`。长期AI处理器需要用
SRAM宏扩大容量，并通过hit-under-miss、多MSHR或banking解除blocking tail；这属于后续
流水化Cache微架构工作，不应通过继续缩短line规避。

## 9. D-cache与流水线理想收益评估

### 9.1 数据访问trace的统计口径

NEMU现在可以输出紧凑的架构数据访问trace。记录点位于成功完成的load/store访存处，只记录
普通内存访问，不记录取指和MMIO。当前NEMU未启用虚拟内存，因此trace中的虚拟地址与物理
地址相同；引入分页后，D-cache模型应根据实际微架构改为记录地址翻译前或翻译后的地址。

在`ysyx-workbench/npc`下执行：

```sh
make dcachesim-trace DCACHE_TRACE_SCALE=test
make dcachesim-run DCACHE_TRACE_SCALE=test
make dcachesim-explore DCACHE_TRACE_SCALE=test
```

`dcachesim-trace`使用NEMU运行MicroBench并生成二进制mtrace；`dcachesim-run`评估一组参数；
`dcachesim-explore`扫描容量、line和路数。当前模型采用write-back、write-allocate和精确LRU：

- load/store miss都会分配新line；
- store hit只设置dirty，不立即向下层写数据；
- 替换dirty line时统计一次完整line写回；
- 跨line的数据访问会拆成两个Cache line访问，但仍只计为一条架构访存指令；
- MMIO不进入Cache，也不参与本次mtrace统计。

归一化burst模型中的D-cache阻塞时间为：

```text
blocking TMT = refill占用时间 + dirty writeback占用时间
```

这个定义比`miss count * refill latency`更完整。写回Cache可能拥有较低miss率，但如果工作集
持续修改数据，被替换的脏line仍会占用写地址、写数据和写响应通道。

### 9.2 MicroBench test的D-cache探索

2026-08-22使用RV32 NEMU运行MicroBench `test`，生成98857条架构数据访问，其中load为
52774条，store为46083条。1KiB、2-way、32B line结果为：

| 指标 | 结果 |
| --- | ---: |
| Hit / Miss | 94608 / 4249 |
| Hit Rate | 95.7019% |
| Compulsory / Capacity / Conflict | 1231 / 2653 / 365 |
| Dirty eviction | 3290 |
| 归一化critical TMT | 55933 cycles |
| 归一化blocking TMT | 79639 cycles |
| 其中dirty writeback | 32900 cycles |
| Refill / Writeback流量 | 135968B / 105280B |

脏块写回约占该配置blocking TMT的41.3%。因此只根据95.7%的命中率估算D-cache收益会明显
偏高。对72组参数扫描后，归一化blocking TMT较低的候选包括：

| 容量 | Line | 路数 | Miss | Hit Rate | Blocking TMT |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 8KiB | 64B | 4 | 1258 | 98.7275% | 43468 |
| 8KiB | 64B | 2 | 1289 | 98.6961% | 44489 |
| 8KiB | 32B | 4 | 2380 | 97.5925% | 46840 |
| 8KiB | 64B | 1 | 1368 | 98.6162% | 46890 |

这些数据只能用于候选排序，不能直接宣称RTL会得到对应加速比。最终选择还需要综合面积、
命中路径时序、真实SDRAM写回延迟，以及代表目标AI软件的数据访问trace。当前array若继续
使用标准单元，8KiB D-cache会远超课程面积预算；后续应使用SRAM宏，再实现参数化、阻塞式
PIPT、单MSHR、write-back/write-allocate、独立writeback buffer和MMIO uncached路径。

### 9.3 RTL计数器给出的理想收益上限

仿真性能监视器现在直接使用整数计数器计算理想上限，不修改被测CPU的功能路径，也不会进入
综合。2026-08-22运行：

```sh
make perf NPC_CONFIG=rv32-baseline PERF_SCALE=test
```

MicroBench十项测试全部通过。PMU计分窗口为1818657 cycles、430203条退休指令、IPC
0.236549；完整仿真统计为3284092个active cycles、832171条退休指令、IPC 0.253395。

先定义访存指令超过基础一周期的额外开销：

```text
memory_excess = memory_execution_cycle_sum - memory_instruction_count
              = 1316766 cycles
```

神谕单周期数据存储器假设所有load/store都只占基础一周期，但保留当前前端、控制流和其他
开销。它没有模拟任何具体D-cache，不能当作可实现D-cache的预期收益：

```text
oracle_data_memory_cycles = active_cycles - memory_excess
                          = 1967326 cycles
oracle_data_memory_speedup = 3284092 / 1967326 = 1.669x
```

这是任何D-cache都不可能超过的数据供给收益上限，因为现实中仍有命中延迟、miss、写回、
uncached访问和结构冲突。

I-cache的额外miss开销直接由原始整数计数器计算，避免用打印后的小数平均值反推：

```text
icache_miss_excess = miss_response_latency_sum
                   - miss_count * average_hit_latency
                   = 308529 cycles
```

理想单发射流水线假设每周期退休一条指令，但保留当前数据访存额外开销和I-cache miss额外
开销：

```text
ideal_pipeline_cycles = retired_instructions
                      + memory_excess
                      + icache_miss_excess
                      = 2457466 cycles
ideal_pipeline_speedup = 3284092 / 2457466 = 1.336x
```

最后同时假设理想流水线和神谕单周期数据存储器，仅保留一条指令一个基础周期与当前I-cache
miss开销：

```text
ideal_pipeline_and_oracle_data_memory_cycles
    = retired_instructions + icache_miss_excess
    = 1140700 cycles
combined_ideal_speedup = 3284092 / 1140700 = 2.879x
```

`1.669x`、`1.336x`和`2.879x`都不是未来RTL的承诺值。前两项也不能直接相乘，因为两种优化
消除的周期集合需要按同一基线重新组合。`1.669x`只说明当前执行时间中数据访存额外周期占比
较高，不能证明加入现实D-cache比流水线更划算。手册比较的是面积约束下可实现D-cache的
性价比：同容量D-cache因写路径、dirty状态和写回控制而比I-cache更大，而当前23000 um^2
课程预算几乎没有剩余空间。工程顺序应先实现五级流水线和精确stall/flush，再在采用SRAM宏
的配置中加入D-cache，最后用相同workload、统计窗口和真实miss/writeback代价计算实际收益。
