# I-cache 容量与替换探索：第二阶段

本文件保存模型筛选阶段的记录；后续真实库负载、RTL及综合选型见
[结构与替换选型](ICACHE_SELECTION_2026-09-21.md)。下文“下一步”属于当时的阶段结论。

## 冻结的范围与判据

本阶段承接[第一阶段](FRONTEND_EXPLORATION_2026-09-21.md)。保留其全部源码和结果，
新增模型与输出目录，不改变默认 RTL、综合策略或既有计时规则。

先扫描 256 B、512 B、1/2/4/8/16 KiB，1/2/4 路，16/32 B 行；全部使用合法的二进制索引。
先比较 FIFO、LRU、SRRIP、插入3的RRIP、BRRIP，再加入同组映射、必须安装新行的
离线 Belady OPT。OPT 使用未来地址，只表示该轨迹上替换选择的理论空间，绝不作为在线候选。
不把容量翻倍的收益归给策略。新容量按面积/时间的取舍比较，不宣称满足第一阶段的5%面积预算。
同容量新策略仍须优于最强简单对照，最终采用门槛保持执行时间改善3%、最坏保留输入退化不超过3%。

第一阶段六个开发输入继续作为诊断，已经看过的六个保留输入不能充当第二阶段的新保留集。
新增 MicroBench test 的完整功能轨迹作为容量诊断，不作为边缘AI的代表性证据或独立保留集。
在开发集确定值得实现的容量与机制后，必须加入代码规模更大的边缘AI代理和新的预定保留输入，
方可声称泛化有效。不能用旧三种小程序的更多输入冒充更大指令工作集。

## 模型层次

仓库原有 `tools/cachesim/cachesim.cpp` 是 C++ LRU 模型，`explore.py` 扫参数。
第一阶段另写了 `scripts/model_frontend.py`，用于快速比较 FIFO/LRU/RRIP，并以基线
取指/退休事件筛选退休反馈。后者固定了基线事件时刻且假设立即安装，只能初筛。
最终性能数据来自真实 Verilator RTL，不来自 Python 推导。

本阶段 `scripts/scan_icache_capacity.py` 读取 RTL 的退休PC CSV或NEMU的RLE二进制轨迹，
顺序模拟组、tag、有效性与策略状态。连续同一行的访问只压缩存储，保留次数，确保
miss后的hit仍会提升RRIP。所有在线策略只能看当前和过去；OPT单独计算未来访问位置。
RRIP相同优先级按驻留插入顺序选择，本模型不声称与RTL的物理way编号逐事件一致。
输出 miss、每千指令miss、工作集行数及需求回填字节；没有CPU周期、IPC或面积预测。
原始trace、镜像、命令和模型哈希随输出保留。

`scripts/trace_microbench_cache.py` 在独立目录复制 NEMU、AM、MicroBench，
以 RV32I+Zicsr 和现有软件乘除法辅助例程编译。仅复制件的NEMU计时器改为指令序号，
使功能轨迹可重复；**该日志的时间和分数没有性能意义**。它不是SoC版的同镜像对照。
实际性能继续由原有 SoC/RTL 计时流程测量，原工作区NEMU配置和AM代码不变。

## 研究候选的边界

- [Mockingjay，HPCA 2022作者论文](https://www.cs.utexas.edu/~lin/papers/hpca22.pdf)
  与[作者artifact](https://github.com/ishanashah/Mockingjay)：从二值重用分类扩展到重用距离预测，
  根据预计下一次使用距离选victim。原方案面向2 MiB/core、16路LLC；其表、采样器和每行
  时间状态不能直接加到本核。若OPT显示足够空间，再筛选小型在线距离预测，独立核算采样、
  签名、预测表、每行状态和更新端口；缩减实现不称为完整复现。
  作者仓库提供ChampSim策略源码，标明Apache-2.0；本阶段没有复制该代码。
- [ICARUS，ASPLOS 2026作者论文](https://www.cse.iitb.ac.in/~biswa/ASPLOS2026.pdf)：
  结合指令关键性与重用信息管理L2。原系统有64 KiB L1I、2 MiB L2及解耦前端，
  不能直接套到阻塞式L1I。需先确认“关键/非关键取指”在本核是否有可区分的群体，
  否则增加关键性预测器只会增加成本。本轮未取得可核验的作者公开artifact。
  该论文也指出仅按PC分类的Hawkeye/Mockingjay用于指令访问效果有限；因此不会把
  数据缓存策略直接换名移植。应单独验证历史上下文和局部重用距离是否提供额外区分能力。

本阶段先回答容量曲线和替换上限，不先承诺某个论文机制会胜出。
若OPT相对简单方案也无明显剩余空间，优先研究缓存结构和存储实现，避免继续增加替换状态。

## 可复现入口

在 `npc` 目录执行，输出路径必须尚不存在：

```sh
python3 scripts/test_icache_capacity_model.py
python3 scripts/trace_microbench_cache.py --output result/frontend-capacity-replay/microbench --scale test
python3 scripts/scan_icache_capacity.py \
  --trace result/frontend-capacity-replay/microbench/microbench.trace.bin \
  --output result/frontend-capacity-replay/microbench-scan.json
g++ -std=c++17 -O3 -Wall -Wextra -Wpedantic -Werror \
  tools/cachesim/cachesim.cpp -o result/frontend-capacity-replay/cachesim-reference
python3 scripts/check_icache_scan.py \
  --scan result/frontend-capacity-replay/microbench-scan.json \
  --reference result/frontend-capacity-replay/cachesim-reference \
  --output result/frontend-capacity-replay/crosscheck.json
```

此处只交付模型筛选；模型产生的 miss 比不直接称为加速比。真实 RTL、正确性、
综合/STA仍是任何新默认配置或新机制必须通过的后续步骤。

## 本次筛选结果

原始输出在 `result/frontend-capacity-20260921`，有效MicroBench轨迹是
`microbench-v3/microbench.trace.bin`。程序使用RV32I，全部10项校验通过；完整轨迹
872,053条指令、4,332个唯一PC、1,130个16 B代码行。重复采集的SHA256完全一致。
它包含启动、外设初始化、打印与校验，不是SoC原生Total或Scored窗口；这里只比较同一轨迹。
其中NEMU图形初始化也在轨迹内；禁止把全轨迹miss直接套入MicroBench的计时窗口。

下表统一为两路、16 B行、冷启动，数字为功能模型miss次数：

| 数据容量 | FIFO | LRU | SRRIP | 离线OPT |
| --- | ---: | ---: | ---: | ---: |
| 256 B | 24,840 | 20,844 | 24,474 | 17,092 |
| 512 B | 8,419 | 7,358 | 8,418 | 6,154 |
| 1 KiB | 3,284 | 3,169 | 3,261 | 2,646 |
| 2 KiB | 2,425 | 2,316 | 2,439 | 1,896 |
| 4 KiB | 1,691 | 1,546 | 1,699 | 1,362 |
| 8 KiB | 1,313 | 1,190 | 1,317 | 1,157 |
| 16 KiB | 1,177 | 1,135 | 1,179 | 1,135 |

结果说明：

- 更大的代码覆盖下，512 B并不普遍够用。1/2/4 KiB仍有明显的容量变化，应进入下一轮
  RTL/面积取舍。当前数据阵列使用标准单元映射，不能按商业SRAM面积直接外推容量成本。
- LRU比此次RRIP变种强，必须升级为后续RTL的简单对照；不能只让新方法胜过FIFO就宣布有效。
- 2 KiB时，OPT比LRU少420次miss，即18.13%的miss空间；4 KiB约11.90%。这是同映射
  下的功能轨迹上限，尚不包含策略硬件成本，更不表示同百分比的执行时间收益。
- 8 KiB的剩余空间仅33次miss，16 KiB在本轨迹上已没有OPT优势。较大容量下继续加入复杂
  替换预测器未必合算；需要更大边缘AI程序验证，不能据此推广到全部负载。
- 旧六个代理开发输入在512 B两路时，各策略与OPT均相同，只有20/30/38次首次访问miss。
  这进一步确认了旧负载对大缓存策略的区分能力不足。

完整几何、策略与需求回填字节数见 `proxy-dev-scan.json`、`microbench-scan.json`。
32 B行虽然通常减少miss事件，但每次回填翻倍；这里尚未裁定其RTL执行时间是否更优。
没有使用旧保留集重新调参，没有测新的RTL周期/面积/STA，也没有修改默认配置。

验证包括：五项模型测试（OPT对穷举、压缩前后等价、直接映射、非法参数、二进制格式）；
另以原有C++ CacheSim对独立输入逐配置核对LRU和访问总数。结果见
`cpp-crosscheck.json`与`microbench-crosscheck.json`。第一阶段24个交付文件哈希仍一致。
首次NEMU配置缺少AM初始化需要的VGA外设，第二次遇到已有无显示编译路径的问题，
分别保留在`microbench`和`microbench-v2`；有效运行启用原有VGA实现并使用SDL dummy驱动。

下一步以1/2/4 KiB和同容量LRU为结构对照，先扩大可校验的边缘AI代码覆盖并冻结新保留输入，
再筛选“历史上下文是否改善重用预测”。新策略的无上下文版本用于消融；只有通过模型、
真实RTL及面积/STA比较后，才决定是否替换默认配置。此筛选没有证明某个新算法已经有效。
