# RV32 寄存器与额外周期审查

对象：面试分支 `c253a1a`，`rv32-baseline`。检查当前综合清单的 45 个模块及 5 个 package，
按实际 RV32 配置分析寄存边界、握手和状态机；仿真与历史实验另外分类。
本轮没有修改 RTL。下列节省量是结构分析，尚未通过修改后的综合或 microbench 测量。
本文保留审查时的状态；随后落实情况见[周期优化验证](RV32_CYCLE_OPT_2026-09-19.md)。

## 优先处理的接口问题

`riscv32_dcache` 的 tag/data 读口在普通状态下持续读取输入地址，没有在旧响应反压时保持
对应的阵列读出值。定向测试先装入 cache line，再让命中响应停在 `ready=0`；撤销请求
valid 后把输入地址改到同一行下一字。旧响应从 `0x59585b5a` 变成 `0x5d5c5f5e`，违反
响应保持约定。保持原输入地址的控制用例通过。

这是已复现的独立 D-cache 接口缺陷；尚未证明当前整核程序会触发。当前 LSU 在等待期间
保持上下文，WB 又恒 ready，掩盖了该边界。优化前应让 S1 有效且未完成时保持 tag/data
读出值，仅在允许接收下一查询时更新；victim 采集和 clean 仍按各自状态使用读口。
修复不需要增加一份完整响应寄存器，但必须复测连续 store/load 的读写旁路。

## 候选项与具体取舍

| 优先级 | 位置 | 当前代价 | 建议与限制 |
| --- | --- | --- | --- |
| 高 | IFU 预测信息表 | 4 × 33 bit，现有网表确有 132 个 DFF | 当前 I-cache 最多一个已接受但未响应的查询，改为一项 33 bit 上下文，理论减少 99 bit；同沿旧响应消费/新请求接收、redirect 后旧响应都要正确配对。IFU 中尚未交给 cache 的两项队列仍需各自保留预测。 |
| 高 | LSU 完成后的入口 | `req_ready` 仅在 IDLE 为 1，旧访存完成拍无法接下一条 | 成功完成并交付 WB 的同拍接收年轻请求；保留请求寄存边界。连续独立 D-cache hit 的 LSU 接收间隔理论可由 3 拍变 2 拍。异常、WB 反压和恢复时禁止重叠。 |
| 高 | I-cache AXI 请求入口 | miss unit 已寄存请求，adapter 还要再等一拍才出 AR | 增加空闲时的请求直通，AR 受阻时保存上下文；本地请求与 AR 可同拍握手，理想情况下每次 miss/uncached fetch 少 1 拍。D-cache AXI 已有这一结构。 |
| 高 | D-cache miss 状态机 | INVALIDATE → SEND_REFILL，以及 INSTALL → RETURN_RESPONSE 各自串行 | 失效旧行与发回填请求可以同拍；全部 R/B 成功后，安装与返回可同拍，理想成功 miss 合计少 2 拍。不能提前越过尚未返回的写回错误，响应反压时也只能安装一次。 |
| 中 | D-cache 脏行写回缓冲 | miss unit 与 AXI adapter 各保存 128 bit，网表中两份都存在 | 统一 line buffer 所有者，有望少 128 bit。必须改清接口对数据保持期限的约定，不能在原有“握手后生产者可改 payload”的契约下直接删 adapter 寄存器。 |
| 中 | IFU taken 预测 | 接受 taken 响应时禁止新查询，下一拍才查目标 | 已寄存的预测目标可在响应消费当拍作为下一查询地址，省去这个查询空拍；同步调整 flush/epoch 与 PC 推进。目标选择会进入 BHT/BTB 查询路径，需要测可通过频率。 |
| 中 | 重定向寄存器 | 分别保存 3 个来源，再选择；有效映射载荷共 94 个 DFF | 可先选最高优先级来源，再只存一份目标；或进一步试验取消该寄存级以减少恢复延迟。前者增加寄存器前的 mux，后者延长纠错到 PC/flush 的路径。仅保留单级时，载荷也不需要异步清零。 |
| 后续 | LSU 请求派发、uncached AXI 入口 | 正常访存先入 LSU 上下文；uncached 再入 adapter 上下文 | 分别试验空闲直通，最多各减少一个请求发出周期；保持时仍需保存上下文。会延长 EX/AGU → PMA/cache/AXI 的路径，应与通过频率一起比较。 |
| 后续 | load-use 前递 | LSU 数据必须先进入 WB，消费者才可读到 | 加成功 load 完成到 ID/EX 的前递可减少相关等待，但把 cache/AXI 响应、数据格式化与操作数选择串起来；不得旁路错误响应或较老的同名寄存器值。 |

前四项优先级较高，因为可缩小存储或消除局部交接等待，保留现有顺序执行和提交结构。
上表的局部周期收益不能直接相加为程序收益：部分等待会被 cache miss、前端不足或数据相关覆盖。

## 需要单独实验的时序选择

- `branch_predictor` 查询已是 BHT/BTB/RAS 并行读取、一级响应；BTB 内部没有两级查询流水。
  训练入口仍有寄存器，映射训练载荷 64 个 DFF；RAS 也先寄存栈操作再更新。
  可以试验从 EX 结果直接训练，减少状态并提前一拍生效，但会合并目标地址计算与写表路径。
- IFU 请求队列和 fetch buffer 均无空队列直通；空队列入队后下一拍才能使用。
  满队列也不接受同拍出队腾出的空间。这些选择切断 ready 反馈，不影响持续未满时的一拍一条。
  空队列直通与满队列滚动接收应分别试验，不能把队列容量本身当成固定多级流水。
- ID/EX skid 是额外容量，正常无停顿时不增加一拍；其载荷在网表中约 311 个 DFF。
  删除可省面积，但会把下游 ready 拉回译码，且减少短时反压缓冲。应比较单项弹性寄存器版本。
- EX 结果级和 WB 保存不同指令，不能按“重复结果”直接合并。它们还参与老 LSU 完成时
  年轻 ALU 的顺序约束、异常恢复及前递；改成更短流水线需要重新设计这些条件。

这些寄存器中确有为时序而保留的选择。应实际比较 `程序周期 / 通过时序的频率`，允许降频，
不能把历史时序注释当作永久保留依据，也不能把删掉寄存器等同于运行更快。

## 逐组检查结论

以下模块名省略 `riscv32_` 前缀；精确文件清单和源码哈希见证据目录。

| 模块 | 本轮结论 |
| --- | --- |
| `core` | 装配与组合连接，无额外顶层流水寄存器；刚修复的老异常阻塞必须保留 |
| `branch_predictor`, `bht`, `btb`, `ras` | 并行组合查询已合理；训练暂存列入后续实验 |
| `ifu`, `fetch_buffer` | 预测表可缩小；taken 空拍和队列直通列入候选 |
| `pma` | 纯组合属性译码，无状态或额外周期 |
| `icache`, `icache_tag_array`, `icache_data_array` | hit 已由同步阵列直接响应，无重复 S2；数据阵列低电平写入的 staging 用于保持锁存窗口稳定，保留 |
| `icache_miss_unit`, `icache_axi` | critical word 响应缓冲承担反压，错误历史防止错误安装，保留；AXI 请求入口可直通 |
| `idu`, `operand_mux`, `regfile` | 译码/操作数选择/GPR 读取均为组合，没有恢复旧 RR 级；GPR 仅存 x1..x31 |
| `id_ex_reg`, `exu`, `ex_result_reg` | EXU 无寄存器；skid/结果级属于时序与顺序设计取舍，不能按结构体声明宽度估算可省面积 |
| `lsu`, `data_mem`, `uncached_axi` | data_mem 已可同拍释放/接收；LSU 入口尚不能，uncached 仍保留入口寄存边界 |
| `dcache`, `dcache_tag_array`, `dcache_data_array` | hit 路径已有 store 同址旁路；先修反压期间阵列输出不保持的问题 |
| `dcache_miss_unit`, `dcache_axi` | victim 已连续逐字采集，B 与 refill 已重叠；候选为状态合并和双 line buffer，不能声称仍是逐字两拍采集 |
| `completion_mux`, `wb_reg`, `commit` | mux/commit 纯组合，WB 是唯一提交寄存边界，没有额外 commit stage |
| `csr_file`, `pmu` | 可变 CSR 字段已压缩；64 位计数器是架构状态，仿真统计没有混入 |
| `hazard_ctrl`, `interrupt_ctrl`, `trap_ctrl` | hazard/trap 纯组合；中断恢复 PC 必须跨周期保存，不能用当前取指 PC 替代 |
| `redirect_stage`, `fence_i_ctrl` | redirect 载荷可合并；FENCE.I 的 drain/clean/invalidate 顺序有数据一致性用途 |
| `axi4_arbiter`, `axi4_router` | 地址请求直通，状态只锁事务来源/目标；末响应与新地址同拍交接是次要候选，需要两层共同修改，不能把两层等待简单相加 |
| `axi4_clint` | 计数/比较和读响应快照具有语义；AW 后一拍才收 W 可优化，但定时器访问很少，优先级低 |
| `reset_controller` | 复位同步与下降沿释放有用途，不作为流水冗余删除 |
| `npc_system`, `npc_axi`, `core_reset_boundary`, `axi4_soc_width_converter` | 顶层负责接线；RV32 同宽转换为组合直通，RV64 分支的缓冲不构成当前硬件开销 |
| 5 个 common package | 类型、编码和参数；未使用字段及常量是否占硬件由展开/综合决定 |
| `sim/`, `experiments/` | 不属于本次芯片冗余；不删除历史实验，也不通过改仿真访存延迟来制造性能提升 |

## 证据与后续验收

[本轮证据](../../result/verification/rv32-register-cycle-audit-20260919/)包含 `state-inventory.json`、
寄存器统计脚本、D-cache 反压复现测试、精确构建命令和两个结果日志。网表来自上一轮实际
综合，50 个当前输入的 SHA256 与该次测量一致。DFF 数量是当前事实，优化后的面积尚未测量。

建议顺序：修正 D-cache 保持条件 → 缩小 IFU 预测表 → LSU 完成拍接收 → I-cache AR 直通 →
D-cache 状态合并 → 缓冲共享与前端时序实验。每项分别对比；功能验证保留精确异常、中断、
总线反压与错误响应，性能使用相同 microbench 镜像/计时窗口/访存模型，再测综合与 STA。
