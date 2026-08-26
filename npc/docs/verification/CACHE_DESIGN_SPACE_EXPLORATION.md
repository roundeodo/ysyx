# Cache 设计空间探索方法

状态：保留并继续使用

## 1. 工具定位

`cachesim`是metadata-only cache参考模型。它读取地址trace，只维护tag、present、dirty、
替换状态和事务统计，不保存真实指令或数据内容。它适合快速回答：

- 给定workload在不同容量、line大小和路数下有多少miss；
- compulsory、capacity和conflict miss如何变化；
- write-back D-cache产生多少dirty eviction；
- 在给定缺失代价下，哪个参数组合的TMT趋势更好；
- RTL cache的miss统计是否和参考模型一致。

它不能独立决定最终配置，因为它不包含RTL关键路径、SRAM宏、总线竞争、预取污染和完整
流水线反压。

## 2. 为什么使用trace

对于一次确定的架构执行，提交指令PC序列和已执行load/store地址序列是确定的。NEMU可以
比RTL快得多地产生这些序列，因此一次trace能够被许多cache参数组合重复使用。

- I-cache trace保存提交PC；
- D-cache trace保存普通内存load/store地址、方向和大小；
- MMIO不进入D-cache trace；
- 错误路径访问不在架构trace中，因此该模型适合cache几何探索，不用于评估错误路径污染。

进入乱序和预取阶段后，架构trace仍可用于容量下界分析，但真实访问时序和推测访问必须由
RTL或更详细的微架构模拟器评估。

## 3. 缺失代价模型

工具支持三种口径：

- `fixed`：直接使用RTL PMU校准出的critical-word和完整refill周期；
- `independent`：每个beat按独立事务估算；
- `burst`：一次地址握手后连续传输多个beat。

优先使用RTL校准的`fixed`模型做最终排序。transport模型只用于理解burst、beat宽度和line
大小的趋势，不能替代真实控制器测量。

关注两个不同指标：

- critical response penalty：miss开始到原请求word可交付的周期；
- complete refill penalty：miss开始到整条line安装完成、cache可以接收下一事务的周期。

阻塞式cache的吞吐通常由完整refill时间决定；支持hit-under-miss后，两者的权重会改变。

## 4. 基本命令

在`ysyx-workbench/npc`目录执行：

```bash
make cachesim-test
make cachesim-trace CACHE_TRACE_SCALE=test
make cachesim-run
make cachesim-explore
```

评估D-cache：

```bash
make dcachesim-trace DCACHE_TRACE_SCALE=test
make dcachesim-run
make dcachesim-explore
```

校准不同line大小在当前RTL和内存模型中的缺失代价：

```bash
make icache-calibrate-penalty ICACHE_CALIBRATION_SCALE=test
make cachesim-explore-calibrated
```

较长的正式探索把`test`改为`train`，并记录commit、镜像hash和生成CSV路径。

## 5. 3C分类

同一组参数至少运行三组参考模型：

1. 无限容量全相联模型用于识别compulsory miss；
2. 同容量全相联模型用于识别capacity miss；
3. 目标组相联模型产生总miss。

由此得到：

```text
compulsory = infinite fully-associative misses
capacity   = finite fully-associative misses - compulsory
conflict   = target misses - finite fully-associative misses
```

若模型使用LRU、round-robin等不同替换策略，必须在结果中注明，不能把差值全部归为路数影响。

## 6. 从模型到RTL

候选配置进入RTL前必须完成：

1. cachesim筛选miss/TMT趋势；
2. 确认参数满足RTL几何约束；
3. 运行cache定向测试和完整回归；
4. 比较RTL PMU与cachesim的请求、hit、miss；
5. 测量周期、Fmax、array实现和面积；
6. 用代表性AI代理负载复核，不只使用MicroBench。

模型和RTL miss不一致时，先检查trace口径、uncached地址、`fence.i`、替换策略和错误路径访问，
不能直接修改模型去匹配RTL。

## 7. 结果记录要求

每一行结果必须至少包含：

- Git commit；
- workload和输入规模；
- trace格式版本及hash；
- capacity、way、line和替换策略；
- refill模型及所有周期参数；
- hit、miss、MPKI、dirty eviction、critical penalty和blocking TMT；
- 对应RTL周期、IPC、频率和存储实现。

不同口径结果分表保存，不做跨表排名。

