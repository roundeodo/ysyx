# RV32 等待周期复查

基线 `71e44bf`，范围为 RV32 面试版本硬件清单中的 45 个模块和 5 个 package。
检查请求/响应是否已经可用、旧事务是否已结束、是否只是为了假设的接口通用性而等待。
缓冲负责反压时保存数据，不自动构成“正常传输必须多等一拍”的理由。

## 检查清单

模块名省略 `riscv32_`。表中“保留”表示本轮检查后的电路取舍，不表示已证明不存在其他优化。

| 模块 | 检查结论 |
| --- | --- |
| `pma` | 组合属性译码，无请求寄存器和等待状态 |
| `bht`, `btb`, `ras` | 表/栈为算法状态，查询组合，解析事件直接训练；训练到同拍查询的旁路会改变读写冲突规则，本轮保留已有规则 |
| `branch_predictor` | 唯一响应寄存器切断“预测目标→下一次查表→预测目标”的反馈；不能直接改成无条件组合直通 |
| `ifu` | 请求队列已空队列直通、满队列交接；已呈现的受阻请求必须保持，旧 epoch 返回继续排空 |
| `fetch_buffer` | 已空队列直通、同拍出入；剩余两项容量用于吸收真实反压 |
| `icache` | 命中同步读后直接返回；已删除失效扫描 FSM，排空后一次清有效位 |
| `icache_tag_array` | 有效位单独保存，提供全表失效；tag 仍不清零，同步读保留 |
| `icache_data_array` | 读级与请求身份对齐；写暂存保证低电平锁存阵列的写窗口稳定，保留 |
| `icache_miss_unit` | miss 分配直发 refill、关键字响应空缓冲直通；事务身份、错误历史和反压缓冲保留 |
| `icache_axi` | 空闲 AR 已直通，R 已直通；SEND 只处理地址反压，剩余 burst 按实际 beat 排空 |
| `idu` | 组合译码；普通 FENCE 不再排空无关 ALU/WB，访存仍由阻塞 LSU 排序；CSR/FENCE.I/MRET 的串行化保留 |
| `regfile`, `operand_mux` | GPR 异步读、前递组合选择；x0 无物理存储，没有独立 RR 级 |
| `id_ex_reg` | 单项弹性执行上下文；已删除 skid，保留反压与 flush 边界 |
| `exu` | 组合 ALU/AGU/分支运算，没有多周期 FSM |
| `ex_result_reg` | 保存较老普通结果、预测校验及异常身份；与年轻 LSU 发射的年龄约束共同保留 |
| `lsu` | 空闲直通和成功完成交接已存在；本地异常不直接抢完成口，避免超过较老 EX 结果 |
| `data_mem` | 旧响应按保存的路由返回；新 AXI payload 按实际通道 valid 选择，移除年轻 LSU 发射允许条件到宽地址 mux 的路径 |
| `dcache` | hit 已交接及字节前递；clean 已跳过无需写回的 way，并在检查完当前 set 的同拍读下一 set |
| `dcache_tag_array`, `dcache_data_array` | 同步读保留；同沿 store/read 的前递由顶层统一负责，不重复增加一套 |
| `dcache_miss_unit` | 分配拍启动首字读取或 clean-victim refill；最后必要 R/B 当拍安装并完成，反压才保留响应 |
| `dcache_axi` | AR/AW/W 空闲已直通，R/B 已直通；独立通道进度和写回到 B 的所有权保留 |
| `uncached_axi` | 成功 R/B 交付与新请求交接；错误和反压不开放该窗口，AW/W 各自保持 |
| `completion_mux`, `commit` | 纯组合；LSU 完成优先，commit 没有额外寄存级 |
| `wb_reg` | 唯一提交寄存边界，保存当前提交指令并取消年轻完成；不能仅按结构体相似合并 |
| `csr_file`, `pmu` | CSR 组合读、提交写；计数器与可变 WARL 字段是架构状态，无额外访问 FSM |
| `hazard_ctrl` | 组合检查；最近生产者、老异常、老 LSU 与恢复约束保留，不按 stall 总数直接删除 |
| `interrupt_ctrl` | 保存架构恢复 PC；等待已发出的事务完成，避免中断截断副作用 |
| `trap_ctrl`, `redirect_mux` | 纯组合优先选择，无额外恢复周期 |
| `fence_i_ctrl` | 保留 drain/clean/invalidate 顺序；本轮缩短下层维护完成延迟，未改成维护重叠执行 |
| `core` | 装配、事件与连接，无顶层附加流水寄存器 |
| `axi4_arbiter`, `axi4_router` | 已支持末响应交接新地址；受阻地址所有者、事务来源/目标、独立 AW/W 进度保留 |
| `axi4_clint` | 已支持末 R/新 AR、旧 B/新 AW/W 同拍交接；计数、AR 时刻快照和计时分频保持 |
| `reset_controller` | 同步与复位释放时序保留，不作为指令等待删除 |
| `core_reset_boundary`, `npc_system`, `npc_axi` | 综合、系统和 SoC 的实例化边界，没有多余流水状态 |
| `axi4_soc_width_converter` | RV32 同宽分支五通道已直通；RV64 拆包状态不在 RV32 硬件中，不能算当前面积冗余 |
| 5 个 common package | 类型、常量、参数与辅助函数；不同配置的分支按实际展开判断，不按源码长度估算硬件 |
| `sim/`, `experiments/` | 分别为仿真环境与历史实验，不属于本轮有效硬件；不改变设备延迟制造收益，不删除历史源码 |

## 验收口径

定向用例检查直通的具体握手沿、反压保持、错误、旧/新事务身份和副作用次数。
整核检查精确异常、中断、DiffTest 与位级组合环。面积、STA 和 microbench 使用冻结源码；
比较相同程序、cache/预测器参数、设备延迟模型和原生 timer 窗口。
模块延迟下降不能替代最终执行时间改善；时序未通过的频率只用于定位问题，不作为成绩。

## 实测取舍

三个候选依次加入改动，原始源码、失败报告和网表保留在 `result/performance/rv32-wait-opt-{a,b,c}-20260919/`。
A 加入 I-cache 分配/关键字直通和 uncached 交接；B 再合并 I-cache 失效和 D-cache miss 完成；
C 调整 AXI 请求选择，并加入 clean 扫描、CLINT 交接及普通 FENCE 优化。最终保留 C。

| 候选 | 面积 μm² | 600 MHz data setup 余量 | microbench test Total 周期 | 结论 |
| --- | ---: | ---: | ---: | --- |
| 基线 `71e44bf` | 69,580.014 | +0.005 ns | 3,603,144 | 比较起点 |
| A | 69,388.760 | −0.018 ns | 3,576,624 | 此频率不通过，继续调整 |
| B | 69,398.070 | −0.146 ns | 3,553,445 | 此频率不通过，继续调整 |
| C | 69,536.922 | +0.034 ns | 3,553,436 | 四组时序通过，保留 |

面积使用相同 Nangate45 typical、Yosys/Slang `DELAY 0`，范围是处理器核、复位控制器及
扇出上限 16 的 `BUF_X4` 复位树，**不含 CLINT 和整个 SoC**。DFF 从 7,647 降至 7,640，
数据锁存器仍为 2,048。C 的 data hold、gating setup/hold 分别为 +0.059、+0.061/+0.097 ns。
这是综合后理想连线结果；600 MHz 已重查通过，未把报告中的 Fmax 当作布局布线后的频率。

| 原生 microbench **test**，600 MHz | 基线 | C |
| --- | ---: | ---: |
| Total 定时器时间 | 6.005 ms | 5.923 ms |
| Total 同窗口 IPC | 0.212130 | 0.215102 |
| Scored 定时器时间 | 2.624 ms | 2.595 ms |
| Scored 同窗口 IPC | 0.273317 | 0.276482 |

Total 周期减少 **1.38%**，IPC 增加 **1.40%**，面积减少 **0.062%**，面积收益很小。
程序二进制、工具、cache/预测器参数、外设 100 MHz 等效延迟及 CLINT 每微秒加一的口径相同。
原程序计时窗口保持；IPC 用同一窗口的退休数/周期数，宿主仿真耗时不参与比较。
Total 中包含打印，计时数值改变会影响格式化指令数；Scored 的退休数均为 430,311。

## 验证与保留边界

- 精确异常 **40/40**、RV32 DiffTest **35/35**、定时中断 **8/8** 通过。
  新增普通 FENCE 前有延迟老 load 的检查，年轻访存仍不能超过它。
- D-cache miss 定向 **24 项**覆盖 R/B 先后、错误、反压、分配与最终响应的准确握手沿；
  完整 D-cache 检查覆盖全 set/way 脏行写回及干净 cache 扫描延迟。
- I-cache 覆盖关键字直通、唯一响应、单字行、反压期间失效；uncached 覆盖 **24 种**
  读写交接/错误/反压组合。CLINT 检查旧新 ID、受阻响应、AW/W 分开到达。
  共享 RTL 的 RV64 I/D-cache、miss、LSU 和 uncached 用例也通过。
- standalone/SoC lint 完成，完整 `npc_system` 位级检查 **0 个组合环**。
  原有宽结构体 `UNOPTFLAT` 提示仍在，不能把 lint 完成写成无警告。
- 最终 microbench **10/10**，同一仿真器的观察器开关结果一致；宿主测试 **8/8**。
  短程序波形独立核对 21 次提交/19 次退休及两个 timer 窗口，验证计数边界。

同步读、反压保持、剩余 burst 排空、写回错误确认和精确异常年龄约束继续保留。
D-cache miss 完成沿不同时启动新 lookup，避免引入安装/同步读冲突的额外旁路；预测器的
反馈边界和 FENCE.I 维护阶段也没有强行合并。本轮没有对这些进一步方案做收益验证，
也没有做全状态形式化证明，因此不能声称所有可能的冗余都已消除。

完整对照见 [comparison.json](../../result/performance/rv32-wait-opt-c-20260919/comparison.json)，
回归见 [checks.json](../../result/performance/rv32-wait-opt-c-20260919/checks.json)。
本轮未跑 **train**，不能把上述 test 数据写成 train 成绩；手动复测命令：

```bash
cd /home/yong/ysyx/ysyx-workbench-rv32-interview/npc
python3 scripts/run_microbench_perf.py --scale train --cpu-mhz 600 --verify-observer \
  --output result/performance/rv32-wait-opt-train-600
```
