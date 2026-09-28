# RV32IM 前端时序优化

保留 **700 MHz、106,339.086 μm²** 的 RV32IM 配置。相对本轮起点 640 MHz，频率提高
9.375%，面积增加 0.243%。**720 MHz 仍未通过整核 STA**，不作为可用频点。
本轮只改 `riscv32_icache_replacement.sv`；核对全部 RTL 哈希，后端与基线相同。

## 基线与口径

起点是[上一阶段最终电路](RV32IM_TIMING_2026-09-28.md)：commit
`47c852e12b9ce086b872095f59cf54fbe5a6fda6` 加已有工作区修改，不等同于该 commit。
原研究、乘除法、地址电路和延迟模型修改均保留。本轮基线、差异及源码快照保存在
`npc/result/rv32im-720-20260928/`；可入库的小型证据见
[data/rv32im-720-2026-09-28](data/rv32im-720-2026-09-28/README.md)。

配置仍为 I-cache 1 KiB/4路/32 B/policy 13，D-cache 256 B/2路/16 B，BHT 16项，
BTB 16项/两路/完整目标、策略0，方向策略0，RAS 4项。NanGate45 typ、Slang/Yosys、
AREA3、820 MHz 映射目标、复位树和 I/O 约束与起点一致；没有修改延迟模型或放宽约束。
iEDA 检查数据及门控时钟的 setup/hold，20 MHz 网格实测通过点和上邻失败点。
频率是综合后估计，不是布局布线或硅上测量；820 MHz 只是相同的映射目标。

## 问题与电路

起点的长路径从 AXI 写响应经过访存完成、恢复/进度、ID ready，到 I-cache 命中握手，
再串联 RRPV 命中旁路和 victim 比较。后端信号到达较晚，但前端把整个比较链放在其后，
因此可以先优化前端组合电路，不需要改变后端流水线。

保留方案将“原 RRPV 的 victim”与“命中路提升为0后的 victim”提前并行计算。
后者直接读 tag 命中向量，避免经过由握手门控的路号编码。hit 握手、同组判断和分段
条件只选择最终路号，仍在原 tag 查询边界采样。无新寄存器、周期、等待或请求；
同拍命中前递、低路号平局规则、反压保持、失效和分配优先级不变。
详细结构只维护在[替换模块说明](../microarchitecture/ICACHE_REPLACEMENT_DESIGN.md)。

## 同条件对照

| 方案 | 面积 / μm² | 全组通过 / MHz | 上邻失败 / MHz | 取舍 |
| --- | ---: | ---: | ---: | --- |
| 本轮 RV32IM 基线 | 106,081.598 | 640 | 660 | 对照 |
| 并行计算两种 victim，握手最后选择 | **106,339.086** | **700** | **720** | 保留 |
| 上项加独热向量直接更新 RRPV | 106,573.698 | 660 | 680 | 退频，拒绝 |
| 并行候选再用 RRPV 等级向量选择 | 106,784.636 | 700 | 720 | 同频面积更大，拒绝 |
| 保留电路关闭 M | 101,878.798 | 760 | 780 | RV32I 无退化，默认仍为720 |

局部 RTL 更短不保证整核映射更好；没有按局部运算符数量作取舍。
保留方案的 DFF 8,428、数据 latch 8,192、clock gate 546 均与起点相同。
700 MHz：数据 setup +0.007 ns、门控 setup +0.007 ns、数据 hold +0.060 ns、
门控 hold +0.094 ns，全部通过。720 MHz 数据与门控 setup 均为 −0.025 ns，终点仍为
RRPV 状态及其时钟门控。余量较小，因此只按此工艺角、此综合后口径报告。

等级向量候选在720 MHz 下的前端路径已通过，但 AXI 访存输出还有两条 setup 违例，
最差 −0.019 ns，起点为 ID/EX 操作数，经过地址计算和 uncached 请求分发。
它说明只看某条前端路径改善仍不足以宣布整核达到720；该候选最终仍只通过700，
而面积更大，因此没有保留。此结果也不构成“以后不可能达到720”的结论。
本轮按优先修前端的要求，没有扩大后端修改范围。

RV32I 的原默认720 MHz也单独复验：数据 setup +0.085 ns、门控 setup +0.073 ns、
数据 hold +0.059 ns、门控 hold +0.094 ns。没有把 RV32I 的760 MHz成绩用于 RV32IM。

## 正确性与周期

以下对应最终保留源码，源文件哈希与综合快照相同：

- 策略13～16各在2/4/8路下与 C++ 模型比较，12组通过，覆盖同拍查询/命中旁路。
- I-cache 21项检查；IFU taken循环100次连续交付；fetch buffer 1,012次输出、
  746次同拍交接、34次flush检查通过。
- NEMU DiffTest：2,803个算术/别名/RAW/访存用例，以及 misa/精确陷阱自检通过。
- 精确异常40/40、FENCE.I/非分支恢复/总线错误100/100通过。
- 700 MHz配置的计时器/中断测试通过，包括除法中途IRQ、访存未完成、AM、
  CLINT反压、IFU连续redirect与旧epoch排空。保留原断言与错误用例。

相同点积/归一化镜像在修改前后：RV32I 软件均为2,385,341周期/2,065,811退休指令，
RV32IM软件均为192,451周期/151,125退休指令，镜像哈希和结果相同。
这是同一 M 硬件上的 standalone 平坦存储模型整程序计数；比较时仿真器仍使用起点
640 MHz参数，排除了调整主频影响。之后的计时器回归使用新的700 MHz默认配置。
固定周期数下，640→700 MHz对应时间降低8.57%，但100 MHz外设等待不会等比例缩短，
不能将这个比例当作 SoC train 的实测加速。**本轮没有重跑完整 train。**

## 复现

在 workbench 根目录使用新输出目录，不覆盖冻结结果：

```sh
export NPC_HOME="$PWD/npc"
python3 npc/scripts/test_selection_replacement.py --output /tmp/frontend-replacement \
  --policies 13 14 15 16
make -C npc git_commit= NPC_CONFIG=rv32im-balanced \
  test-icache test-fetch test-pipeline test-precise-exception test-fence-i test-timer-interrupt
python3 npc/scripts/measure_execute_ppa.py --output /tmp/frontend-ppa --name rv32im
python3 npc/scripts/measure_execute_ppa.py --output /tmp/frontend-ppa --name rv32i --m-enable 0
```

PPA 的 `--source-root` 接受含 `npc/vsrc` 的快照；替换测试的新增 `--rtl-root` 接受
`riscv32` 目录，用于隔离候选。精确编译命令、镜像哈希和测试命令见机器记录。
`rv32im-balanced` 默认700 MHz；运行 train 的原完整命令应显式使用
`--isa rv32im --cpu-mhz 700 --timing-model device-clock`。旧命令若显式传580/640，仍按旧频率运行。
