# I-cache设计空间探索

## 1. 目标

本工具实现手册所述的第一类`cachesim`：NEMU负责执行程序并输出架构动态PC序列，独立的
元数据Cache模型重放该序列。它用于低成本比较容量、Cache line大小和路数，不代替RTL
功能验证、综合、STA或完整系统性能测试。

当前流程只回答：在同一条动态指令流下，不同Cache几何参数会产生多少次需求取指miss。
它不模拟指令内容、AXI时序、refill状态机、错误路径取指、预取、多MSHR和miss重叠。

## 2. 文件和职责

| 文件 | 职责 |
| --- | --- |
| `tools/cachesim/cachesim.cpp` | 解析PC trace，维护组相联LRU元数据，统计Hit/Miss、3C、AMAT和TMT |
| `tools/cachesim/explore.py` | 并行启动多组cachesim，排序并生成CSV |
| `tools/cachesim/tests/test_cachesim.py` | 用确定性地址序列验证冲突miss、容量miss和日志解析 |
| `nemu/configs/riscv32-cachesim_defconfig` | 构建可执行、启用完整itrace的RV32 NEMU |
| `nemu/configs/riscv64-cachesim_defconfig` | 构建可执行、启用完整itrace的RV64 NEMU |

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
  CACHE_TRACE_FILE=result/cache/riscv32_crc32_nemu_itrace.log
```

该目标会将NEMU活动配置切换为`riscv32-cachesim_defconfig`。后续运行DiffTest前，使用
`make nemu-ref-rv32`或`make nemu-ref-rv64`重新生成对应reference。

### 3.3 评估单组参数

```sh
make cachesim-run \
  CACHE_TRACE_FILE=result/cache/riscv32_crc32_nemu_itrace.log \
  CACHE_CAPACITY_BYTES=8192 \
  CACHE_LINE_BYTES=32 \
  CACHE_WAYS=2
```

### 3.4 扫描参数组合

```sh
make cachesim-explore \
  CACHE_TRACE_FILE=result/cache/riscv32_crc32_nemu_itrace.log \
  CACHE_SCAN_CAPACITIES=4096,8192,16384,32768 \
  CACHE_SCAN_LINE_SIZES=16,32,64 \
  CACHE_SCAN_WAYS=1,2,4 \
  CACHE_SCAN_JOBS=4 \
  CACHE_SCAN_OUTPUT=result/cache/cachesim_riscv32_crc32_exploration.csv
```

`CACHE_MISS_PENALTY_CYCLES`默认沿用当前32B line RTL测得的284.142 cycles。该数值不能
直接代表16B或64B refill。得到不同line大小的RTL实测数据后，应使用：

```sh
make cachesim-explore \
  CACHE_MISS_PENALTY_BY_LINE_SIZE=16=150,32=284.142,64=520
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
  CACHE_SCAN_OUTPUT=result/cache/cachesim_riscv64_microbench_test_exploration.csv
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
capacity和conflict miss。当前8KiB、2-way、32B line使用统一284.142 cycles miss penalty
估算得到AMAT 2.2316 cycles、TMT 167643.78 cycles。

同为8KiB、2-way时，16/32/64B line分别产生1135/590/316次miss，但refill流量分别为
18160/18880/20224B。更大的line减少miss却增加传输流量；在获得各line大小的真实refill
代价前，不能仅按当前统一penalty下的AMAT排序。

## 5. 设计结论的证据要求

正式参数选择至少需要：

1. 能代表目标AI软件栈的长时间动态PC序列；
2. 每种line大小在RTL/SoC中测得的critical-response和完整refill代价；
3. 候选方案对应的SRAM面积、命中路径时序和功耗；
4. 在RTL PMU上复核Hit/Miss、AMAT、前端阻塞周期和IPC。

当前NEMU committed itrace不包含redirect后的过期取指。它适合需求取指设计空间探索；未来
验证分支预测、预取和错误路径污染时，应另外记录NPC I-cache请求握手trace，不能混用两种
统计口径。
