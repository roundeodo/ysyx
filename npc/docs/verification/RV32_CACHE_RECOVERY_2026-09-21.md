# FENCE.I 与脏写回错误修复

基于开发提交 `7dfa2d6`（对应远程发布 `9e64976`）的本轮工作树。
[原问题与复现](../../result/verification/rv32-fence-error-audit-20260921/README.md)，
[本轮证据](../../result/verification/rv32-fence-error-fix-20260921/)。本轮没有重跑 train。

## 修复与边界

| 问题 | 当前处理 | 正常路径代价 |
| --- | --- | --- |
| FENCE.I 后新指令携带旧 taken 预测 | 提交时恢复前端；维护期间停止新预测；旧 I-cache 请求保持到握手并按 epoch 排空；失效完成后重新查询 | 维护期间不再预先生成预测；普通取指不新增流水级 |
| 非分支无法纠正错误 taken | EXU 在普通/LSU 分流前检查，当前指令成功交付时恢复 PC+4；只清年轻项，老异常/分支恢复优先 | 增加组合检查与第 4 个 redirect 来源，不增加寄存级 |
| clean 错误被当成成功 | 维护控制器进入 FAILED，停止后续取指和执行，阻止中断；只能复位退出 | 增加维护错误状态；不为已退休 FENCE.I 伪造精确异常 |
| 脏替换失败丢失旧数据 | 排空 R/B 后，用已有 victim 缓冲逐字恢复原行，最后恢复 tag/present/dirty，再向当前访问报错 | 正常读写重叠不变；错误时增加每行字数个恢复周期，无第二个整行缓冲 |

clean 失败采用不可恢复策略；普通脏替换失败则保留本核可继续访问的完整旧数据，允许软件处理
当前访问异常并重试。当前 SoC 没有维护错误通知接口，不承诺软件恢复 clean 失败、复位保留脏数据，
或回滚下层已经完成的部分写入。电路与状态归属分别见[流水线](../microarchitecture/PIPELINE_DESIGN_RECORD.md)
和[D-cache](../microarchitecture/DCACHE_DESIGN_RECORD.md)。

## 验证结果

| 检查 | 覆盖与结果 |
| --- | --- |
| 全核 84 例 | 旧 JAL 改为 NOP、整数、load、store、JAL、CSR、非法指令；4 组总线反压/延迟；维护协议与独立旧预测注入；MMIO 副作用及提交后继检查；访存异常；clean 的 SLVERR/DECERR、部分写回、失败时定时中断被阻止；真实 trap handler 读取旧 store 并重试替换。全部通过 |
| D-cache 恢复 75 例 | R/B 先后、SLVERR/DECERR、部分写回、load/store miss、响应反压、连续失败、逐字旧数据恢复、后续成功 clean。全部通过；同一新测试可在修复前 RTL 上复现旧数据丢失 |
| 维护控制器 10 例 | FENCE.I 提交前已经受阻的请求保持到握手、旧 cache 事务排空、维护阶段等待、失败保持及复位退出。全部通过 |
| miss 接口 306 例 | RV32 16 B 行、RV32 单字行、RV64 32 B 行各 102 例；补充逐字恢复、元数据、错误响应时点检查。全部通过 |
| 共用 RV64 RTL | 缓存恢复 75 例、EXU、fetch 通过；未把这些单元测试表述为完整 RV64 系统验证 |
| 原有回归 | 精确异常 40/40、DiffTest 35/35、定时中断、RV32 D-cache/EXU/pipeline/fetch 通过 |
| 静态检查 | NPC/SoC lint 通过；Yosys/Slang 综合与位级 SCC 检查通过，0 组合环。Verilator 的聚合总线 UNOPTFLAT 提示仍存在 |

全核正常场景由软件执行指令训练 BTB，不修改内部状态。独立恢复场景在预测结果写入响应寄存器前
注入错误 taken，保留响应保持协议，以验证后端纠错本身；不关闭 RTL 断言。
写回错误模型允许丢弃全部或只保存部分写入，验证不依赖“错误一定撤销写入”。

原 miss 测试要求任意最后响应都当拍完成；现仅对成功/无需恢复的访问保持该要求，脏行错误必须
等待恢复。另修正 `test-dcache-miss` 未创建新配置构建目录的问题。中间失败日志保留，最终结果以
`final-core.log`、`final-directed.log`、`single-word-final.log`、`rv64-cache-final.log` 和 `final-checks.json` 为准。

## 面积、时序与性能

同一 RV32 baseline、NanGate45、core + reset 边界；测量 RTL 快照与最终 RTL 的 SHA256 一致。

| 项目 | 修复前 | 修复后 |
| --- | ---: | ---: |
| mapped cell area | 69,575.758 μm² | 69,469.358 μm²（−0.153%） |
| 600 MHz data setup slack | +0.062 ns | −0.017 ns，未通过 |
| 600 MHz MicroBench test Total cycles | 3,544,972 | 3,545,481（+0.0144%） |
| 600 MHz Total 原生时间 / IPC | 0.005908 s / 0.215609884 | 0.005909 s / 0.215580622 |
| 600 MHz Scored cycles / IPC | 1,552,076 / 0.277248666 | 完全相同 |

同频比较已核对 binary、ELF、工具与其他运行输入一致。600 MHz 结果仅用于 RTL 周期对照，
不作为修复后硬件通过该频率的证据。新增恢复会把写回错误判断接入 miss 完成条件；本次关键路径
从数据 AXI 响应输入经过完成/请求交接到数据 AXI 输出，没有通过加流水寄存器处理。

590 MHz 的 slack 显示为 `-0.000`，详细报告仍标注 VIOLATED，不能按浮点 `>= 0` 当作通过。
**580 MHz** 的 data setup/hold 与 gating setup/hold 分别为 **+0.018 / +0.060 / +0.096 / +0.096 ns**，
详细报告无违例。本轮按 580 MHz 作为通过当前综合 STA 的频率；这不是布局布线后的频率保证。

580 MHz 下 MicroBench **test**：Total 原生时间 **0.005987 s**，同窗口 IPC **0.220133883**；
Scored 原生时间 **0.002626 s**，IPC **0.282824147**。观察器开关对照通过。
降低 CPU 频率时设备延迟的周期换算也改变，因此跨频率 IPC 上升不能当作硬件结构优化收益。
计时窗口及模型限制沿用[计时规则](MICROBENCH_TIMING_RULES.md)；短计分窗口的微秒量化也会带来累计误差。
完整数据见[同条件对照](../../result/verification/rv32-fence-error-fix-20260921/comparison.json)、
[580 MHz 软件报告](../../result/verification/rv32-fence-error-fix-20260921/test-580/report.json)。

## 重跑

在仓库根目录执行：

```sh
make -C npc git_commit= NPC_CONFIG=rv32-baseline test-fence-i test-fence-i-ctrl test-dcache-recovery
make -C npc git_commit= NPC_CONFIG=rv32-baseline test-dcache-miss test-precise-exception test-timer-interrupt
python3 npc/scripts/run_microbench_perf.py --scale test --cpu-mhz 580 --verify-observer
```

测试、汇编程序、参数与构建命令在 `npc/tests/`、`npc/scripts/test_cache_recovery.py` 及本轮 manifest 中维护。
