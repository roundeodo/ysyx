# RV32 双请求 LSU 与 D-cache hit-under-miss

2026-10-01。已实现可选的两项 LSU 上下文和单 miss 下的 load 命中返回。
保持顺序发射、ROB4 和队首 store/MMIO 授权，没有加入新的 Issue/完成流水级。
默认开关仍为 `NPC_LSU_ENTRIES=1`、`NPC_DCACHE_HIT_UNDER_MISS=0`；不把定向程序的收益当作应用收益。

## 选择依据

当前顺序发射核缺少 BOOM 的乱序发射窗口。直接引入完整 LDQ/STQ、未知地址投机、关联搜索和
违例重放，既不能解除 Issue 处的寄存器依赖，也会扩大面积和错误恢复范围。
本次选择 CVA6 风格的独立返回身份，结合 HPDcache 的缺失行预留与按阻塞原因重试思路。
这是针对本核的裁剪实现，不是移植其完整 LSU，也没有同工艺证明本核优于它们。

实际核对过 CVA6、HPDcache、Rocket、BOOM、CV32E40P、Ibex；版本、文件哈希及不同前提见
[开源项目比较](../learning/LSU_DCACHE_DESIGN_REVIEW.md)。电路、状态、旁路和恢复条件见
[并发访存设计](../microarchitecture/LSU_CONCURRENCY_DESIGN.md)。

## 测量边界

基线 HEAD `5493a6aec976f4f9bdc075834d3f1202b0ae16ef` 已带未提交修改，实际基线为开工前快照及
117 项源码哈希，不能只凭 commit 重建。已有修改和结果删除均保留；本轮没有提交或推送。

固定 RV32IM、流水乘法、ROB4/load overlap；I$ 1 KiB/4 路/32 B/策略13；D$256 B/2 路/16 B；
BHT16、BTB16×2、RAS4。MicroBench **test** 使用同一未插桩镜像、100 MHz 设备时钟和
`device-clock-v1` 模型；没有修改 APB/AXI 延迟。主机运行时间不进入 CPU 性能结论。

CLINT 为 1 MHz tick。CPU 周期和退休数由只读观察器在相同定时器窗口累计。
多请求下，计时读取的 PC 来自本拍真实发出的 LSU 请求，或 uncached adapter 保存的事务 ID，
不能从固定槽位取得。观察器开关后的计时事件和提交审计相同。
Scored 退休数始终为 317724；Total 还包含时间格式化和输出等工作，跨频点不要求其退休总数相同。

## 已确认的周期效果

| 同 680 MHz，MicroBench test | Total 周期 | Scored 周期 | Scored IPC |
| --- | ---: | ---: | ---: |
| 开工前单请求基线 | 2204695 | 928906 | 0.342041068 |
| 两项 LSU，仍阻塞 D-cache | 2204695 | 928906 | 0.342041068 |
| 两项 LSU＋hit-under-miss | 2204069 | 928471 | 0.342201318 |

完整方案 Total 减少 **0.0284%**，Scored 减少 **0.0468%**，收益很小。
原生 Total 都打印 3.242 ms；Scored 打印值为 1.368/1.365 ms，但它是十个 1 μs 量化窗口之和，
不能据此宣称精确减少 3 μs。微小差异以同窗口周期为准。部分子程序也有轻微退化。

同一汇编、同一 557 条退休指令、NEMU 对照的定向程序中：
“两个 load 后接独立 DIV/MUL”从 1742 降到 1606 周期，减少 **7.81%**；
全命中情况从 1618 降到 1606。提前在软件中调度 DIV/MUL 的旧实现原本也是 1606 周期，
新硬件消除了该例对手工调度的需要。它是 flat-memory 整核测试，不是 SoC train 时间。

既有 int8 dot/normalize 量化代理（RV32IM）仍为 192352 周期，未获加速。
本轮没有跑完整 train，也没有测完整 AI 推理模型。

## 为什么容量等待减少很多，程序却几乎不变快

| Scored 窗口中的互斥派发分类 | 单请求 | 完整方案 |
| --- | ---: | ---: |
| LSU 容量不足 | 60238 | 5011 |
| RAW 等待 | 218970 | 249941 |
| ROB 满等待 | 43041 | 65625 |
| 访存顺序约束 | 102905 | 103119 |

新结构实际出现 621 次已有访存时再接收请求、289 次 miss 期间命中，双项同时占用 34292 周期。
因此并发确实打通。较老 miss 仍限制数据可用和退休，很多等待从 LSU 入口转移到了 RAW/ROB。
上述分类互斥，其他事件计数则可重叠，不能直接相加推算潜在收益。

D-cache miss/refill 数仍相同；本例没有靠增加外部流量获得收益。监视器按事务分别计时。
其 hit/miss 以是否新分配 refill 分类：等旧 refill 后重读命中的请求归入 hit，等待也计入响应延迟，
因此平均 hit 延迟不等于同步阵列的一级命中延迟。

## 正确性与取舍

已验证：同组其他路命中、同行第二请求仅一次回填、第二 miss 重读、响应反压稳定、槽位复用、
局部未对齐异常、PMA 错误、写回失败后旧脏行恢复、回填报错与其他命中并存；12 个随机种子。
后端有 36 组双请求取消/迟到错误/恢复同拍测试；缓存错误恢复75组、FENCE.I整核100组、
维护控制10组；精确异常、中断、混合FU、量化代理及单槽RV32/RV64回归也通过。
异常/维护整核回归验证的是本轮并发协议；最后的 AXI 等价改写另以独立握手、集成随机和
NEMU 整核回归覆盖，原始 manifest 保留各次测试实际对应的源码哈希。
CSR mscratch 专项由程序自检，其余六项后端程序中的五项使用 NEMU DiffTest。

首轮失败记录没有删除：计数器沿用了单在途断言、综合声明顺序错误，以及将单槽接口测试
误用于双槽配置。这些分别由逐身份断言、声明修正和按各自协议运行测试解决，没有关闭断言。

本次尚不能建议默认启用：MicroBench 收益不足以抵消新增面积和验证复杂度。
没有 store 提前退休，没有多 MSHR，没有越过未发射指令的乱序 Issue；也没有功耗收益测量。
更大 D-cache、store 等待和发射窗口属于后续独立对照，不能算成本轮已经实现的收益。

## 700 MHz 与交接旁路复核

第一版双槽在 700 MHz 的数据 setup 余量为 −8 ps，终点 `data_axi4_manager_o_52_`；
路径为 EX 操作数 → 有效地址 → LSU 请求选择/PMA → 路由允许 → uncached AXI valid。
其余 setup/hold 组通过。没有通过新增寄存器、改变约束或改变综合策略处理该路径。

1. 整体拆分 cache/uncached 的请求窗口，2304 种组合逐项等价，12 个种子回归通过，
   但映射后只通过 660 MHz，面积 122319.036 μm²；时序退化，撤销这项整体改写。
2. 改为只化简 uncached valid 的允许条件，保留原 ready 与路由更新规则。
   uncached 只能在空闲或最后响应交付时发出，不必再次经过 cache 并发容量判断。
3. 定向测试复现了 miss 响应可交付时仍拒绝下一查询的空转。改为响应确实交付且
   阵列无冲突时允许下一 load 当拍启动。原测试明确失败，修改后 12 个种子通过。
   保留同组安装冲突、受阻响应和第二 miss 的同步重读保护。

4. uncached adapter 的 AR/AW/W valid 原来先按状态赋值，再用新请求窗口优先覆盖。
   将“持有通道”和“新请求直通”按互斥来源并行 OR，减少优先选择层。1280 种状态/握手/
   错误组合的 valid 方程等价；独立 AXI 测试的24种交接组合、双槽12种子及整核回归通过。

最终采用第2、3、4项。NanGate45、整核 reset boundary、AREA3、820 MHz 映射点和原 SDC
均保持不变；资格搜索使用20 MHz步长，四类 setup/hold 全部通过才接受。

| 双槽方案 | 合格频点 | 面积 μm² | 700 MHz 最差数据 setup |
| --- | ---: | ---: | ---: |
| 最初已验证实现 | 680 MHz | 122538.752 | −8 ps |
| 最终并行 valid＋交接旁路 | **700 MHz** | **122715.376** | **+28 ps** |

最终700 MHz的门控setup为+35 ps、数据hold为+60 ps、门控hold为+97 ps，零违例。
面积相对最初双槽增加176.624 μm²，约0.144%。720 MHz数据setup为−12 ps，不能使用。
最差路径已从 uncached AXI 输出转移到 `minstret_low_q[31]`；没有为了时序新增流水级。
这属于综合后 STA 资格，不是布局布线后的硅频率保证。

最终单槽仍通过700 MHz，面积121980.950 μm²；双槽相对它增加0.602%。
共享AXI组合改写也使单槽面积比开工前121647.652 μm²增加0.274%，不是零成本改写。
相对开工前单槽，完整双槽面积增加0.878%，700 MHz Scored的面积×时间反而增加0.829%。
因此保留可选实现，默认仍为1/0，不把“达到700 MHz”写成“综合收益最好”。

最终 MicroBench test 在700 MHz：Total2254699周期、IPC0.214110620；
Scored942494周期、IPC0.337109838。原单槽700 MHz分别为2255497/942949周期，
Scored减少455周期（0.0483%）。Total退休数随计时输出格式变化，不能把这部分差别
误判成工作负载指令被删除；Scored退休数仍为317724。
原生计时器打印Total3.221 ms、Scored1.348 ms；周期对应时间为3.220999/1.346420 ms。
Scored原生读数是多个量化窗口之和，不能根据其1 μs级变化推断这项微小收益的方向。
最终680 MHz周期与旁路前双槽完全相同；旁路定向有效，尚未改善该应用的周期数。

原始空转失败在 `rollover-before/seed1.log`；最终回归在 `concurrent-parallel/`、
`uncached-unit-parallel.log`、`core-parallel/`、`kernel-parallel/` 和 `second-load-parallel/`。
最终源码与 PPA 的60个输入、两频点性能仿真的78个RTL文件均核对一致；性能版仅额外包含
已验证不改变结果的只读观察器。证据见 `final-source-check.json`。
磁盘满导致的编译/综合失败单独保留，不能计作功能失败或时序资格结果。

## 复现

```sh
python3 npc/scripts/test_lsu_concurrent.py --output npc/result/lsu-concurrent-recheck
python3 npc/scripts/test_backend_recovery.py --lsu-entries 2 --output npc/result/lsu-recovery-recheck
python3 npc/scripts/measure_execute_ppa.py --backend-rob 1 --load-overlap 1 \
  --mul-pipeline 1 --lsu-entries 2 --dcache-hit-under-miss 1 \
  --output npc/result/lsu-ppa-recheck --name candidate
python3 npc/scripts/run_microbench_perf.py --scale test --isa rv32im --cpu-mhz 700 \
  --mul-pipeline 1 --backend-rob 1 --backend-entries 4 --load-overlap 1 \
  --lsu-entries 2 --dcache-hit-under-miss 1 \
  --icache-bytes 1024 --icache-ways 4 --icache-line 32 --icache-policy 13 \
  --bht-entries 16 --btb-entries 16 --btb-ways 2 \
  --btb-policy 0 --direction-policy 0 --history-bits 4 --ras-entries 4
python3 npc/scripts/summarize_lsu_concurrency.py \
  --input npc/result/lsu-upgrade-20261001 \
  --output npc/docs/verification/data/rv32-lsu-concurrency-2026-10-01
```

原始根目录 `npc/result/lsu-upgrade-20261001/`；性能脚本命令、软件/源码哈希、ISA、设备模型与
实际计时均在各 manifest/report 中。机器可读汇总位于
[data/rv32-lsu-concurrency-2026-10-01](data/rv32-lsu-concurrency-2026-10-01)。
仅清理本轮已完成编译的中间文件，保留仿真器、源快照、日志和清理清单。
较大的已完成日志无损压缩为 `.log.gz`，压缩前后内容哈希一致；重复网表以硬链接去重。

产物保留更新（2026-10-01）：按用户要求清理已核实的大型生成文件；上述原始索引不保证全部可用。小型测量报告与源码哈希保留，删除清单见 `data/cleanup-20261001/`。
