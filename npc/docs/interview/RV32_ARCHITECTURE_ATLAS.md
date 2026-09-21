# RV32 架构与模块说明

更新日期：2026-09-19。独立 RR 已取消；前端查询为一级，训练直接来自 EX 结果。
本轮加入队列和访存直通、load-use 前递及同拍事务交接，删除 ID/EX skid 和恢复寄存级。
当前面积、时序与 IPC 统一见[周期优化验证](../verification/RV32_CYCLE_OPT_2026-09-19.md)。
本文依据面试工作树 `ysyx-workbench-rv32-interview` 的实际连接，配置为
`PROJECT=riscv32 NPC_CONFIG=rv32-baseline`；历史数据不代表本轮成绩。
远程面试快照及依赖恢复方式见 [远程版本说明](RV32_REMOTE_SNAPSHOT.md)。

这是一颗 **RV32I 单发射、顺序执行、顺序提交的处理器**，带分离的 L1 指令/数据缓存、
小型分支预测器、基础 M-mode 异常和定时中断，通过 AXI4 接入 ysyxSoC。
当前没有重命名、ROB、乱序调度、硬件乘除法、MMU、缓存一致性协议或 AI 加速器。
“面向边缘设备”描述应用方向，不能用来代替这些已经实现的结构。

## 1. 阅读顺序与当前参数

先明确 CPU 核、CLINT 和 SoC 的边界，再沿指令的数据流理解流水线、前端、执行单元和缓存，
最后检查前递、异常、中断及恢复条件。下文按这个顺序说明各模块的职责、内部状态和接口。
ALU、AGU、命中选择器等可能只是一个 RTL 模块内部的逻辑，不自动代表独立模块实例。

参数来自 [Makefile](../../Makefile)、[配置包](../../vsrc/riscv32/common/riscv_config_pkg.sv)
及模块内的派生表达式。命令行覆盖参数后，要重新核对文档中的数值。

| 项目 | 当前面试配置 | 含义与限制 |
| --- | --- | --- |
| ISA / GPR | RV32I、Zicsr、Zifencei；32 个 32 位架构寄存器 | x0 恒零，实际数据阵列只存 x1–x31；不是 RV32E |
| 发射 / 提交 | 每拍最多 1 条 / 1 条 | 弹性接口不保证每拍都有可发射指令 |
| 地址 / 指令 / AXI 数据 | 均为 32 位，AXI ID 为 4 位 | 当前数值相同，但语义不同；4 位 ID 不表示 16 个在途请求 |
| I-cache | 256 B，1 路，16 B/行，16 组 | 当前是直接映射；RTL 支持多路配置 |
| D-cache | 256 B，2 路，16 B/行，8 组 | 启用，阻塞式 Write-Back / Write-Allocate |
| I/D 缺失跟踪 | 各 1 个活动缺失 | 不是多 MSHR 非阻塞缓存 |
| BHT | 16 项，每项 2 位饱和计数器 | PC 索引，不是全局历史或 gshare |
| BTB | 总计 16 项，2 路，8 组 | 不要写成“16 组 × 2 路” |
| RAS | 4 项 | 按已解析调用/返回更新，无推测检查点 |
| 预测查询 | 一级结果寄存 | BHT/BTB/RAS 并行组合查询，统一保存预测结果 |
| IFU 请求队列 | 2 项 | 保存待送 I-cache 的 PC/tag/epoch 及预测，不是完成指令队列 |
| frontend tag / epoch | 各 4 个取值，均为 2 位 | tag 配对请求元数据，epoch 区分恢复前后的取指 |
| fetch_buffer | 两项环形 FIFO | 空队列直通；满队列出队时可同拍入队 |
| ID/EX | 单项；无独立 RR | 译码、GPR 读取与前递直接送 ID/EX；反压传回译码 |
| 执行结果 / WB | 各 1 项寄存 | commit 是组合逻辑，不再增加一个寄存级 |
| LSU | 1 个活动请求上下文 | 没有 Load Queue、Store Queue 或 Store Buffer |

## 2. 系统边界与模块层次

当前 SoC 仿真顶层是 `ysyxSoCFull`，其中的 CPU 插槽实例化 `riscv32_npc_axi`。
`riscv32_npc_axi` 包含本地处理器系统及 SoC 接口映射；`riscv32_npc_system` 才负责把
纯核、复位控制、I/D 仲裁、地址路由和 CLINT 连接起来。

```text
ysyxSoCFull                         外部 SoC，不属于纯核
└─ riscv32_npc_axi                  扁平 AXI 插槽接口
   ├─ riscv32_npc_system
   │  ├─ riscv32_reset_controller
   │  ├─ riscv32_core              前端、执行流水线、I/D-cache、CSR 等
   │  ├─ riscv32_axi4_arbiter   合并核的 instruction/data AXI
   │  ├─ riscv32_axi4_router
   │  └─ riscv32_axi4_clint        本地 MMIO 定时器，IRQ 直接返回 core
   └─ riscv32_axi4_soc_width_converter
      └─ RV32 同宽分支             字段映射，无额外寄存级
```

纯核有两个 AXI manager 端口：指令侧只读；数据侧可读写。系统先合并读请求，再把 CLINT
地址送本地定时器，其余请求送 SoC。I/D-cache 独立不意味着拥有两套外部内存带宽。
核内目前无需虚实地址翻译；PMA 按物理地址判断区域属性与权限。

SoC 集成包含 SRAM、MROM、SPI/Flash、PSRAM、SDRAM 以及 UART/GPIO 等外设。
这些属于接入的系统，不能全部称为自行实现的 CPU 子模块。
默认复位 PC 为 Flash 基地址 `0x30000000`，顶层参数允许覆盖。

| RTL 模块 | 内部结构及接口作用 |
| --- | --- |
| [riscv32_npc_axi](../../vsrc/riscv32/system/riscv32_npc_axi.sv) | 扁平 AXI 引脚与结构体信号映射，连接 system 和 width converter；CPU 的外部 slave 端口未提供有效服务，外部 `io_interrupt` 未接成核内外部中断 |
| [riscv32_npc_system](../../vsrc/riscv32/system/riscv32_npc_system.sv) | 本地系统装配层；CLINT 区间 `0x02000000–0x0200ffff` 单独路由，其他地址默认送 SoC |
| [riscv32_reset_controller](../../vsrc/riscv32/system/riscv32_reset_controller.sv) | 异步进入复位，两级上升沿同步，再在下降沿释放；给下游上升沿触发器留出释放时间 |
| [riscv32_axi4_arbiter](../../vsrc/riscv32/system/riscv32_axi4_arbiter.sv) | I/D 读请求轮询仲裁；ARVALID 已展示但受阻时就锁定来源，直到 RLAST 握手才释放；最多 1 个读 burst 在途；AW/W/B 由数据侧独占 |
| [riscv32_axi4_router](../../vsrc/riscv32/system/riscv32_axi4_router.sv) | 地址比较、目标选择及响应返回；读、写分别保存事务目标。读状态为地址路由/返回数据，写状态为地址路由/传送数据/返回 B；不是多在途交叉开关 |
| [riscv32_axi4_soc_width_converter](../../vsrc/riscv32/system/riscv32_axi4_soc_width_converter.sv) | 当前 32→32 位，只做组合字段映射；文件中的 64→32 拆分状态机属于其他配置，不属于当前配置 |
| [riscv32_axi4_clint](../../vsrc/riscv32/system/peripheral/riscv32_axi4_clint.sv) | AXI 读/写状态机、分频计数器、64 位 mtime 和 mtimecmp、比较器；`mtime >= mtimecmp` 产生电平中断；当前没有 MSIP 软件中断寄存器 |

core 和本地 CLINT 接同一个 `clk_i`。CLINT 按所选 CPU 频率产生分频使能，
让 mtime 每微秒递增一次，没有独立的 100 MHz CLINT 时钟引脚。
SoC 设备的 100 MHz 等效延迟模型是另一项配置，见[计时规则](../verification/MICROBENCH_TIMING_RULES.md)。

## 3. 流水线、前递与顺序保证

普通指令的主要路径为：取指缓冲 → 组合译码及 GPR 读取 → 源操作数选择/前递 →
ID/EX → EXU → 执行结果寄存级 → 完成选择 → WB → 组合提交。
访存指令在 EXU 内算出地址后进入 LSU，完成时直接去完成选择器，不经过普通执行结果寄存级。

不能把“取指、译码、执行、访存、写回、提交”六种功能直接说成固定六级流水线。
前端自己有预测寄存级、缓存同步读和队列；后端路径也因指令类型不同而不同。
描述流水线时应明确 ID/EX、执行结果和 WB 等寄存边界。

| RTL 模块 | 具体结构、数据保存与控制 |
| --- | --- |
| [riscv32_core](../../vsrc/riscv32/core/riscv32_core.sv) | 按数据流组织子模块连接、入口握手门控与重定向来源；操作数 mux 和 FENCE.I 状态分别归属独立模块 |
| [riscv32_idu](../../vsrc/riscv32/core/decode/riscv32_idu.sv) | 组合 opcode/funct 译码、立即数生成、rs/rd 使用标志、功能单元选择、CSR/访存/分支控制、非法指令和系统指令分类；不保存独立译码寄存状态 |
| [riscv32_regfile](../../vsrc/riscv32/core/decode/riscv32_regfile.sv) | 2 个组合读端口、1 个上升沿写端口，物理数组 31×32 位；x0 读零、写忽略；其余数据不复位 |
| [riscv32_operand_mux](../../vsrc/riscv32/core/decode/riscv32_operand_mux.sv) | GPR 组合读取、源选择及 EX/结果级/LSU/WB 前递直接形成 ID/EX 输入；CSR 按指令固定地址字段并行读取。停顿期间指令留在 fetch buffer，读取/前递值可随生产者更新，不再保存或刷新 RR 快照 |
| [riscv32_hazard_ctrl](../../vsrc/riscv32/core/control/riscv32_hazard_ctrl.sv) | 组合比较源寄存器和各生产者 rd，生成前递选择、RAW 等待、串行化等待、LSU/执行结果结构阻塞及恢复抑制；不含记分牌 RAM 或指令调度队列 |
| [riscv32_id_ex_reg](../../vsrc/riscv32/core/execute/riscv32_id_ex_reg.sv) | 单项执行包及生产者/串行化元数据；空闲或旧项被接收时 ready，反压保持；flush 清有效位，不清宽 payload |
| [riscv32_ex_result_reg](../../vsrc/riscv32/core/execute/riscv32_ex_result_reg.sv) | 1 项弹性结果寄存，同时保存预测 next PC；在寄存输出端比较真实与预测后继，产生分支纠错请求 |
| [riscv32_completion_mux](../../vsrc/riscv32/core/writeback/riscv32_completion_mux.sv) | 组合二选一，LSU 结果优先，其次普通执行结果；ready 返回对应来源；它没有按 ROB 年龄排序的功能 |
| [riscv32_wb_reg](../../vsrc/riscv32/core/writeback/riscv32_wb_reg.sv) | 1 项弹性寄存，给提交和架构写端提供稳定 payload；架构恢复时清除年轻有效项 |
| [riscv32_commit](../../vsrc/riscv32/core/writeback/riscv32_commit.sv) | 组合生成唯一 commit 事件及 GPR/CSR 写使能，异常抑制正常写回；输出下游 ready 恒为 1。访存副作用不是等到此处才第一次发生 |

### 独立 RR 寄存级是否必需

2026-09-15 已移除独立 RR。GPR 是架构状态存储，其组合读端本身不是一个流水寄存边界。
此前 RR 与 ID/EX 把“译码/原始 GPR 读取”和“操作数准备/前递/CSR 检查”分成两拍；
现在这些组合逻辑由 ID/EX 直接接收，输入反压返回 fetch buffer。
rs1/rs2 地址来自指令固定字段，读 GPR 与其余译码可以并行，不是必须等完整译码结束后才读。

以下是 2026-09-06 的历史直接合并实验，不能当成本次新结果。该候选在 820 MHz 下得到 setup slack −0.105 ns。但原始报告中的
最差终点是 `execute_forwardable_producer_present_reg_p:D`，并非 GPR 读数据寄存器。
该路径的数据到达时间为 1.281 ns，要求为 1.176 ns；路径上一个 NOR4 单元的报告延迟
达到 0.393 ns，其输出扇出为 18。因此失败不能简单归因为“寄存器堆读取太慢”，还涉及
合并后的控制逻辑及负载。RTL 中该生产者标志还依赖 CSR 合法性和异常/功能单元分类。

证据见 [取消 RR 候选的原始时序报告](../../result/performance/rv32-hw-opt-20260906/merge-decode-read/sta/riscv32_core_reset_boundary-820MHz-buffered/riscv32_core_reset_boundary.rpt)。
这个实验只证明当时的直接合并方案不满足既定频率约束，未证明优化控制后仍不能合并，
也未证明保留 RR 的程序执行时间最短：该候选没有完整功能和 train 结果。
本次同时把 CSR 地址选择改为固定指令字段直连，并把串行化 CSR 统一归为等待完成的生产者，
取消 CSR 合法性判断到 EX 即时前递资格的组合依赖。CSR 的异常检查和执行包仍然保留。
取消 RR 时测得网表面积为 76,585.656 μm²；820 MHz setup slack 为 −0.096 ns，降到 750 MHz 后
setup slack 为 +0.018 ns，hold 和门控时钟检查均通过。这里是综合后估算，未做布局布线。
验证和测量结果见 [取消 RR 的实现记录](RV32_RR_REMOVAL_2026-09-15.md)。
同日首次预测器拆分的历史网表为 76,480.320 μm²，采用通过检查的 730 MHz；
最新结果见 [预测器拆分验证](../verification/RV32_PREDICTOR_SPLIT_2026-09-15.md)。

### 前递端点与优先级

两个源操作数均在 **组合译码/读取 → ID/EX** 边界完成相关性处理。四条数据来源按优先级排列：

1. 当前 EXU 的组合结果。
2. 执行结果寄存级的结果。
3. LSU 成功交付的格式化 load 结果。
4. WB 的写回结果。

必须选程序顺序中最近且可用的生产者。匹配到尚未完成的 load 时应等待，不能取更老的
同名寄存器值。数据准备好后才写入 ID/EX，EXU 消费寄存后的操作数。
同拍提交的新值由这套 WB 前递提供；WB 结束后组合 GPR 读取自然看到更新值，无需额外快照刷新或重复的 WB 选择。

load 成功交付时可以直接前递至 ID/EX；故障或反压时继续等待。前递端点位于 ID/EX 之前，
代价是存储响应、数据格式化和操作数选择形成更长组合路径，频率与执行时间必须实测。

### 为什么双完成路径仍然顺序

LSU 未完成时阻止年轻指令离开执行入口。旧 LSU 成功交付 WB 的当拍，允许可执行的年轻
普通指令把结果写入空的执行结果寄存器。年轻结果最早下一拍
参与完成选择，因此不会早于旧 LSU 写回。成功完成时也可接收下一访存，并提供 load 前递；
旧响应始终读旧上下文，故障和反压禁止交接。

SYSTEM、FENCE.I 按串行化处理；普通 FENCE 依靠阻塞 LSU 的访存顺序，不额外排空 ALU/WB。控制恢复在产生当拍抑制年轻执行/副作用，
前端恢复组合直达 IFU。顺序保证来自这些发出与完成条件，不能归因于完成 mux 的优先级本身。

## 4. 前端与分支预测器

当前前端已缩短查询与训练路径；最新验证见
[前端重写记录](../verification/RV32_FRONTEND_REWRITE_2026-09-15.md)。

这里有三个不同的保存位置：预测器的单级响应寄存器、IFU 的两项待发请求队列、
fetch_buffer 的两项已完成指令缓冲。它们保存的数据和释放条件不同，不能合画成一个
“4 项取指队列”，也不能把深度简单相加后宣称可同时处理相同数量的 cache miss。

| RTL 模块 | 内部架构与接口 |
| --- | --- |
| [riscv32_ifu](../../vsrc/riscv32/core/frontend/riscv32_ifu.sv) | PC 状态、2 项请求环形队列及读写指针/数量、随队列保存的预测、唯一已接受请求的在途预测元数据、当前 epoch；向预测器发 PC，收预测后排队访问 I-cache；用唯一上下文配对预测与指令，用 epoch 丢弃旧路径响应 |
| [riscv32_branch_predictor](../../vsrc/riscv32/core/frontend/riscv32_branch_predictor.sv) | 预测控制模块：统一查询握手、PC/epoch 与组合预测对齐、单级响应寄存、最终方向/目标选择和解析事件组合分类；实例化下面三个状态模块 |
| [riscv32_bht](../../vsrc/riscv32/core/frontend/riscv32_bht.sv) | BHT 计数器数组、组合查询和训练更新；由 EX 结果的条件分支解析事件直接训练，没有新增训练寄存级 |
| [riscv32_btb](../../vsrc/riscv32/core/frontend/riscv32_btb.sv) | BTB 数组、有效位和替换位置；组合 set 选择、tag 比较与目标合并，训练直接选 way 同步写入，无查询或训练快照 |
| [riscv32_ras](../../vsrc/riscv32/core/frontend/riscv32_ras.sv) | 调用/返回组合识别、返回地址数组、写指针与数量；组合读取栈顶，解析事件直接更新栈 |
| [riscv32_fetch_buffer](../../vsrc/riscv32/core/frontend/riscv32_fetch_buffer.sv) | 两项环形 FIFO；读、写指针各 1 位，数量 2 位。空队列直通，反压时保存；满队列允许同拍出入，不搬移整条指令 |

| 预测器内部部分 | 当前算法/状态 | 代价与边界 |
| --- | --- | --- |
| BHT | `PC[5:2]` 索引 16 个 2-bit 饱和计数器，初始 01；最高位给方向，条件分支解析后训练 | 无 PC tag，不同分支可发生索引冲突；无全局历史 |
| BTB | `PC[4:2]` 索引 8 组，两路并行比较 `PC[31:5]`；项含有效、tag、目标 PC、控制流种类 | 共 16 项；已有同 tag 项优先更新，否则无效 way 优先，再用轮询替换指针；不是 LRU |
| RAS | 保存 4 个返回 PC、栈指针/计数；依据 x1/x5 调用/返回组合形成 push/pop/pop+push | 根据已解析控制流训练，不在每次预测调用时推测修改；无 RAS checkpoint |
| 唯一查询级 | 按 PC 并行查 BHT/BTB/RAS，完成 tag 比较与目标选择，再保存完整响应 | BTB miss 走 PC+4；返回优先用非空 RAS。反压保持响应，不保存中间 set 和栈顶快照 |
| 训练 | EX 结果交付沿直接更新 BHT/BTB/RAS，无额外训练寄存级 | 来源是执行结果被接收。BTB 直接更新数组，没有待写事务及训练旁路；查询同沿读取旧值 |

当前单级查询是后续前端重写的结果。BHT、BTB、RAS 的模块边界不要求独立流水级；
父模块在一次请求握手时保存 PC、epoch 与最终预测。详见
[预测器模块设计记录](../microarchitecture/FETCH_PREDICTOR_DESIGN_RECORD.md)。

预测器在下游允许时每拍接受查询；taken 响应直接查询目标，连续命中跳转的查询间隔为一拍。
这不等于所有控制流都无退休停顿。真实分支结果不等于预测后继时，
执行结果级触发恢复；IFU 采用新的 epoch，旧响应被接收后丢弃。
已经拉高 valid、尚未握手的 I-cache 请求仍要保持，不能在 redirect 时随意撤回。

`flush_lookup` 清查询流水；FENCE.I 的 `invalidate` 清 BTB/RAS，并拒绝当拍训练；BHT 保留计数器。
BHT 计数器只有复位时初始化，不随该 invalidate 全部清零。不能统一描述为“清空所有预测表”。

## 5. EXU、LSU、CSR 与 PMU

| RTL 模块 | 内部结构 | 关键边界 |
| --- | --- | --- |
| [riscv32_exu](../../vsrc/riscv32/core/execute/riscv32_exu.sv) | 组合整数加减/逻辑/比较/移位、分支条件比较、目标加法、PC+4、CSR 读改写运算、独立访存地址加法器 | ALU、分支、AGU、CSR 执行目前是同一模块内的逻辑区，不是四个独立发射单元；RV32 配置没有硬件乘除法 |
| [riscv32_lsu](../../vsrc/riscv32/core/memory/riscv32_lsu.sv) | 一个紧凑上下文寄存器、3 状态控制、对齐检查、store 数据移位/字节掩码、load 字节选择和符号/零扩展、access fault 转换 | 普通请求空闲直通；受阻时保存重试，本地异常先保存再完成。成功交付拍允许新请求，响应通过 completion ready 反压 |
| [riscv32_csr_file](../../vsrc/riscv32/core/writeback/riscv32_csr_file.sv) | 组合地址选择/合法性判断，M-mode 状态寄存器，内部实例化 PMU；提交写入，trap/mret 修改中断状态 | 实现 mstatus 的 MIE/MPIE、固定 MPP=M，mie.MTIE、硬件 mip.MTIP，mtvec/mepc/mscratch/mcause/mtval、misa 和身份只读值；mtvec 为直接模式，不支持向量表模式 |
| [riscv32_pmu](../../vsrc/riscv32/core/writeback/riscv32_pmu.sv) | 64 位 mcycle、minstret 各拆成高/低 32 位计数段，低半溢出递增高半；mcountinhibit 仅存 CY/IR 两位 | RV32 通过基础及 H 后缀 CSR 访问；异常不算退休，中断不是退休指令；Cache/分支详细统计由仿真 monitor 做 |

EXU 的访存有效地址是 `rs1 + imm`，由独立加法表达式生成；这只是 AGU 功能，尚无地址
翻译。store 数据使用 rs2，和 ALU 的第二操作数选择需要区分。JAL/JALR 返回 PC+4，
真实目标与对齐异常在 EXU 生成，预测后继比较位于后继结果寄存级。

LSU 有三态：空闲时普通请求可直接进入等待响应；下游反压或本地异常进入请求保持态。
保持态重试普通请求或完成本地异常；等待态在成功交付时可接下一请求，故障时禁止交接。

LSU 只保存完成所需字段，不保存整个译码包的所有预测/ALU 控制，减少寄存器。
LB/LH/LW/LBU/LHU 和 SB/SH/SW 使用字节选择、扩展及 WSTRB；不对未对齐访问自动拆成两次
总线事务，而是生成对应异常。上游既有异常、对齐异常不会向存储层发出访问。

## 6. I-cache：同步查询、单缺失与 Early Restart

地址划分为 **tag[31:8]、set[7:4]、word[3:2]、byte[1:0]**。
16 组 × 1 路 × 4 个 32 位字 = 256 B 数据，tag 为每行 24 位，另有有效状态。

命中路径：S0 接受请求，同步读取 tag/data，同时保存请求身份；S1 用数组的寄存输出做
tag 比较和数据选择，返回一个 32 位指令字。不要在数组输出后又凭空添加一个 S2 数据寄存级。
阵列有同步读接口，但 I-cache 的数据存储体使用低电平透明锁存器，refill 写地址/数据/使能
先在上升沿寄存，随后在低电平阶段写入。这与 D-cache 的上升沿触发器数组不同，也不意味着
当前面积结果使用了实体 SRAM 宏。讲面积时要区分接口时序、RTL 存储形式及工艺映射结果。

| RTL 模块 | 内部结构和职责 |
| --- | --- |
| [riscv32_icache](../../vsrc/riscv32/core/frontend/riscv32_icache.sv) | S1 请求寄存、PMA 属性、命中比较/响应选择、替换选择、阵列端口仲裁，以及失效状态机；连接 tag/data/miss/PMA 子模块 |
| [riscv32_icache_tag_array](../../vsrc/riscv32/core/frontend/riscv32_icache_tag_array.sv) | 按 way/set 保存 tag 与有效位；同步读取所选 set 的各 way；按 set/way 写元数据；复位清有效位，tag payload 不依赖清零 |
| [riscv32_icache_data_array](../../vsrc/riscv32/core/frontend/riscv32_icache_data_array.sv) | 按 way/word/set 保存指令数据；上升沿寄存读结果；refill 写口先 staging，再用 always_latch 在低电平写数据存储体，每次写一个字 |
| [riscv32_icache_miss_unit](../../vsrc/riscv32/core/frontend/riscv32_icache_miss_unit.sv) | 单请求上下文、refill 进度、所需字与响应是否已生成的状态；状态为 IDLE → SEND_REFILL_REQUEST → RECEIVE_REFILL → COMPLETE |
| [riscv32_icache_axi](../../vsrc/riscv32/core/frontend/riscv32_icache_axi.sv) | 单读事务控制，空闲时直接发 AR，反压才进入 SEND_AR，地址接收后进入 RECEIVE_R；将 refill 请求变成 AXI AR，把每个 R beat 转成 refill word/错误信息。实例在 core 中，是 I-cache 的同层模块 |
| [riscv32_pma](../../vsrc/riscv32/core/frontend/riscv32_pma.sv) | 组合地址区间译码，给出 readable/writable/executable/cacheable/idempotent 等属性；I-cache 与数据子系统分别实例化它，不是共享单端口寄存表 |

cacheable miss 使用行对齐地址，发 `ARLEN=3`、`ARSIZE=2`、INCR burst，按自然地址顺序
读 4 个 32 位 beat。请求的那个字成功到达后可先返回指令，这就是 Early Restart。
后台仍需接收其余 beat；整行成功后才置 tag 有效。缺失期间不接收另一项普通 lookup，
因此没有 hit-under-miss，也没有 critical-word-first。

PMA 允许执行但不缓存的区域走单次读取，`ARLEN=0`，不安装缓存行；不可执行/非法区域
返回取指异常。若提前返回后后续 beat 报错，整行不能有效，但不能撤回已经交付的指令字。
异常归属应按具体请求字及总线返回语义解释，不能笼统说提前返回等于整行已验证完成。

失效请求先等待旧查询和 miss 排空，在完成握手沿一次清除全部有效位，不再逐组扫描。当前单路无替换选择自由度；配置多路时，优先无效 way，否则用轮询指针，非 LRU。

## 7. 数据子系统与 D-cache

LSU 发的是 load/store 语义请求。data_memory_subsystem 先做 PMA 权限与 cacheable
判断，然后选择 D-cache、uncached 或本地 access fault，并锁定路由直到响应被消费。
这是地址属性选择，不能画成 LSU 自己直接管理 AXI AW/W/B。

D-cache 地址划分为 **tag[31:7]、set[6:4]、word[3:2]、byte[1:0]**。
8 组 × 2 路 × 4 个 32 位字 = 256 B 数据，每行 25 位 tag，另有有效/dirty 位及组替换状态。

| RTL 模块 | 内部结构和职责 |
| --- | --- |
| [riscv32_data_mem](../../vsrc/riscv32/core/memory/riscv32_data_mem.sv) | PMA、D-cache、uncached 三个实例，加 IDLE/DCACHE/UNCACHED/ACCESS_FAULT 路由状态；旧响应按寄存路由返回，新请求独立选路；clean 时由 D-cache 占用端口 |
| [riscv32_dcache](../../vsrc/riscv32/core/memory/riscv32_dcache.sv) | S1 请求、并行 tag 命中比较、way 数据 mux、store 命中字节写与 dirty 更新、store 后继读取旁路、替换选择、维护遍历、阵列读写仲裁 |
| [riscv32_dcache_tag_array](../../vsrc/riscv32/core/memory/riscv32_dcache_tag_array.sv) | 两路 tag/有效/dirty 阵列，同步读取一个 set，定向写一个 set/way 的元数据 |
| [riscv32_dcache_data_array](../../vsrc/riscv32/core/memory/riscv32_dcache_data_array.sv) | 两路同步读目标字，上升沿按 way/set/word 和 byte enable 写触发器数据阵列；命中读取与 victim 数据采集共享读口 |
| [riscv32_dcache_miss_unit](../../vsrc/riscv32/core/memory/riscv32_dcache_miss_unit.sv) | 一个 miss/clean 上下文，4 字 victim 缓冲、替换/回填字索引、请求字数据、写响应 pending 和错误累计；调度脏写回、refill、store 合并、安装与结果返回 |
| [riscv32_dcache_axi](../../vsrc/riscv32/core/memory/riscv32_dcache_axi.sv) | 独立读 FSM（AR/R）和写 FSM（AW/W/B），保存地址及 beat 进度，行数据由 miss unit 保持到 B；读回填与旧行写响应可重叠，并非多个需求 miss 在途 |
| [riscv32_uncached_axi](../../vsrc/riscv32/core/memory/riscv32_uncached_axi.sv) | 单个非缓存事务，状态为 IDLE、SEND_AR、RECEIVE_R、SEND_AW_W、RECEIVE_B；AW/W 各自跟踪接受情况，成功 R/B 交付时可同拍接新请求，错误时禁止交接 |

**命中。** S0 同步查 tag/data，S1 比较并响应。load 返回选中字，扩展在 LSU；store 在
响应握手时按字节更新数据并置 dirty，不立即写下层。store hit 与下一次 lookup 可同拍
发生；顶层保存前一次 store 的位置、数据和掩码，为后继读和 dirty 判断提供显式旁路。
响应反压时阵列输出与旁路一起保持。该旁路与核内 load-use 前递分别处理不同的数据相关。LSU 单活动事务仍限制端到端吞吐。

**缺失。** 优先无效 way，再选轮询 way。干净替换可直接进入失效/refill；脏替换先用同步
读口采集 4 个 victim 字，交给 line adapter 后即可发起新行读，不必等旧行 B 才发 AR。
但最终安装和成功完成必须等整行 refill 及必要的写响应都成功。store miss 在 refill 时
按掩码合并写入字，新行安装为 dirty；load miss 安装为 clean。

```text
选择 victim
  ├─脏且有效：同步采集旧行 → 提交整行写回 ───→ 等待/累计 B 结果
  └──────────────────────────────┐             │
                                 ↓             │
                          旧行失效 → refill 4 字
                                       ↓       │
                           合并 store / 保存请求字
                                       ↓       │
                         等待必要 B，并确认全部成功
                            ├─成功：安装 tag/dirty → 返回
                            └─失败：先恢复被覆盖的旧脏行，再返回 access fault
```

上面的处理顺序不表示独立时钟沿：旧行失效与发送 refill 同拍，成功安装与返回也可同拍。

D-cache 当前没有 Early Restart、hit-under-miss、store buffer 或多个需求 MSHR。
阻塞式写回结构降低了并发控制成本，但 miss 会影响整个顺序后端；脏替换还占用写带宽。

**clean。** 顶层按 CHECK_WAY → WAIT_WRITEBACK 遍历各组各路，跨组时同步读取下一组，调用 miss unit
写回 dirty 行；成功后清 dirty 并保留有效数据。它是写回清理，不是把全部 D-cache 行失效。
clean 与普通 lookup 互斥。维护错误的核级处理边界见下一节。

常用 PMA 区域如下；完整端点与开关以 [地址包](../../vsrc/riscv32/common/riscv32_addr_map_pkg.sv)
和 PMA 为准。这里的范围是地址译码窗口，不代表每种实际外设都配置了相同容量。

| 区域 | 起始地址 | 缓存与访问属性 |
| --- | --- | --- |
| CLINT | `0x02000000` | MMIO，读写，不可执行，uncached |
| SRAM | `0x0f000000` | 可读写执行，uncached |
| UART / SPI / GPIO | `0x10000000` / `0x10001000` / `0x10002000` | MMIO，uncached |
| MROM | `0x20000000` | 只读可执行，uncached |
| Flash | `0x30000000` | 只读可执行，cacheable |
| PSRAM | `0x80000000` | 可读写执行，cacheable |
| SDRAM | `0xa0000000` | 可读写执行，cacheable |

## 8. 冒险、异常、中断、重定向及 FENCE.I

| RTL 模块/逻辑 | 架构作用 |
| --- | --- |
| riscv32_hazard_ctrl | 数据相关、生产者可用性、串行化、LSU 忙、结果级反压或有效异常及恢复门控；控制指令能否接收/发出 |
| [riscv32_interrupt_ctrl](../../vsrc/riscv32/core/control/riscv32_interrupt_ctrl.sv) | 保存下一架构 PC；定时中断使能后阻止新指令进入 ID/EX，让已进入后端的指令排空；后端/维护空闲且无当拍 commit 时受理 |
| [riscv32_trap_ctrl](../../vsrc/riscv32/core/control/riscv32_trap_ctrl.sv) | 组合处理同步 trap、mret、定时中断；生成 CSR 更新字段及架构重定向，同步 trap 优先于 mret，再于中断 |
| [riscv32_redirect_mux](../../vsrc/riscv32/core/control/riscv32_redirect_mux.sv) | 组合选择 4 个来源；优先级为提交 trap/mret/中断 > FENCE.I > 老分支纠错 > 当前非分支纠错；同拍发给 IFU 和前端 flush |
| [riscv32_fence_i_ctrl](../../vsrc/riscv32/core/control/riscv32_fence_i_ctrl.sv) | 提交 FENCE.I 后，停止新预测与取指访存并排空已有请求，clean D-cache，再 invalidate I-cache/BTB/RAS，最后恢复取指 |

**异常链。** IFU 的访问异常、IDU 的非法指令/ecall/ebreak、EXU 的控制流对齐或 CSR
非法访问、LSU 的对齐/总线异常，随对应指令带到 WB/commit；trap_controller 再统一更新
mepc/mcause/mtval/mstatus，跳到 mtvec。年轻指令不应留下架构副作用。
EX 结果级已有有效异常时，即使 WB ready，也会保持年轻 ID/EX 指令并禁止发射，防止年轻
load/store 提前进入 LSU；老异常继续进入 WB，再统一 flush。
已有 AXI 写不能靠 flush 撤销；精确性依赖发出前的顺序约束及目标设备的错误语义。

**中断链。** `CLINT 比较 → mip.MTIP → mie.MTIE 与 mstatus.MIE → 停止入口并排空 →
interrupt_controller 给恢复 PC → trap_controller → CSR 保存现场与跳 mtvec`。
硬件保存的是异常控制状态，通用寄存器上下文由软件处理。mret 使用 mepc 并恢复中断使能。
中断不伪造 commit，不增加 minstret。已接通的是 M-mode 定时中断，不包含外部/软件中断。

**FENCE.I 正常路径。** `IDLE → DRAIN_FRONTEND → CLEAN_DCACHE → INVALIDATE_ICACHE → IDLE`。
已展示 valid 但受阻的请求先保持并完成，再做维护；不能直接撤走总线请求。
维护完成前暂停新预测查询；失效完成后才恢复，避免旧预测快照与新指令配对。
EXU 另有覆盖普通/LSU 两条路径的非分支错误 taken 纠正，交付当前指令时恢复到 PC+4。
clean 失败进入只能由系统复位退出的 FAILED 状态，停止后续取指和提交，阻止中断受理；
不继续 invalidate，也不为已退休的 FENCE.I 补发普通精确异常。恢复策略和电路见
[流水线说明](../microarchitecture/PIPELINE_DESIGN_RECORD.md)，测试与 PPA 见
[修复验证](../verification/RV32_CACHE_RECOVERY_2026-09-21.md)。

## 9. 历史模块、仿真模块与配置声明

文件被 filelist 列出，只说明参与编译，不说明被当前顶层实例化。以下前四个模块已移入
`experiments/`，并从当前仿真、综合及测试依赖中移除；其余按用途保留。

| 文件/模块 | 定位 |
| --- | --- |
| [riscv32_decode_stage](../../vsrc/riscv32/experiments/pipeline/riscv32_decode_stage.sv) | 旧独立译码弹性寄存级；当前 core 未实例化 |
| [riscv32_register_read_stage](../../vsrc/riscv32/experiments/pipeline/riscv32_register_read_stage.sv) | 旧 GPR 读取结果寄存级；2026-09-15 已取消实例 |
| [riscv32_redirect_arbiter](../../vsrc/riscv32/experiments/pipeline/riscv32_redirect_arbiter.sv) | 旧组合优先选择模块；当前 core 使用 `redirect_mux` |
| [riscv32_axi4_error_target](../../vsrc/riscv32/experiments/interconnect/riscv32_axi4_error_target.sv) | 未接入的独立 DECERR 目标；当前系统默认目标为外部端口 |
| [riscv32_core_reset_boundary](../../vsrc/riscv32/system/riscv32_core_reset_boundary.sv) | 综合/STA 使用的“复位控制器 + 纯核”边界，不含 CLINT/SoC，不是实际 npc_system 内又套的一层 |
| [sim/top](../../vsrc/riscv32/sim/top.sv) | standalone 仿真顶层，实例化本地系统、仿真内存/UART 及路由；当前 SoC train 使用 ysyxSoCFull |
| [riscv32_axi4_sim_mem](../../vsrc/riscv32/sim/riscv32_axi4_sim_mem.sv) / [riscv32_axi4_uart_sim](../../vsrc/riscv32/sim/riscv32_axi4_uart_sim.sv) | 仿真 AXI 目标及宿主交互，不是需要计入纯核面积的主存/串口 RTL |
| [riscv32_sim_perf_monitor](../../vsrc/riscv32/sim/riscv32_sim_perf_monitor.sv) | 仿真流水线事件/停顿/预测统计，通过宏控制实例化 |
| [riscv32_sim_icache_monitor](../../vsrc/riscv32/sim/riscv32_sim_icache_monitor.sv) | 仿真取指缓存需求、命中/缺失、延迟等计数 |
| [riscv32_sim_dcache_monitor](../../vsrc/riscv32/sim/riscv32_sim_dcache_monitor.sv) | 仿真数据缓存需求、脏替换、refill 等语义事件计数 |
| [riscv32_sim_issue_window_monitor](../../vsrc/riscv32/sim/riscv32_sim_issue_window_monitor.sv) | 保留的 CSR marker 窗口观察逻辑；不要把它当作当前低侵入计分窗口采样的唯一来源 |
| `riscv32_perf_dpi.svh` 与 C++ 观察器 | 仿真边界导出与宿主统计，不向 workload 插入每条指令一次的 CSR 读指令；低侵入窗口在宿主侧观察已有取时访问 |
| `experiments/riscv32_ALU_for_sta.sv` / `shl4_for_sta.sv` / `bcd7seg.v` | 独立实验模块，不在当前 CPU 活动实例层次中 |
| `common/` 五个 package | 配置、地址映射、AXI 类型、SoC AXI 类型及内部协议/uop 类型定义；package 本身不会实例化硬件 |
| `filelist/` | 仿真/STA 源文件入口及宏；不是处理器模块 |

特别注意配置包仍有 PHYS_REG_COUNT、ROB_ENTRY_COUNT、LOAD_QUEUE_COUNT 等预留字段。
当前没有对应硬件实例，不能据此宣称实现了物理寄存器堆、ROB、LSQ 或乱序发射队列。

## 10. 面试讲解顺序与取舍依据

先讲系统边界，再沿一条 ALU 指令和一条 load 指令走完数据通路，然后补前递、分支恢复、
缓存 miss 和定时中断。最后说明各个参数怎样用实验选择，避免从几十个文件名开始罗列。

| 面试追问 | 可以依据当前代码回答的要点 |
| --- | --- |
| 为什么取消 RR？ | 少一级寄存和传递延迟；同步处理合并后的控制路径。以前直接合并的时序失败不等于独立 RR 永远必需，本次重新验证 |
| LSU 何时才需要保存请求？ | 普通请求允许直通；下游反压时保存重试，已发出时保留完成上下文，本地异常先保存以维持顺序 |
| 为什么删除 ID/EX skid？ | 它是备用容量，不是正常路径必需的一级；单项接收减少面积，代价是反压路径变长，已重新综合验证 |
| load 何时可以直接前递？ | 最近生产者成功交付时允许，错误和反压时禁止；收益是减少 RAW 等待，代价是组合路径变长 |
| 为什么结果级后才判断预测错误？ | 把真实目标生成与预测比较拆开；代价是恢复延迟和分支训练可见性变晚 |
| I/D 为何分别一/两路？ | I-cache 一路简化比较/选择；小 D-cache 两路减轻地址冲突。历史 A/B 支持选择，但不能声称对所有负载最优 |
| 为什么用 WB/WA？ | 保留数据复用，合并重复写；代价是 dirty/victim 状态、写回和 FENCE.I 维护；没有做完整当前 WB 对 WT 扫描就不能给虚构收益 |
| 预测器为何这么小？ | 控制表容量、读选择及训练路径；小表会有别名/容量冲突，训练延迟也会增加短循环或相邻控制流的等待 |
| AXI 支持 burst，为何 IPC 仍低？ | burst 只改善行传输；单读在途、阻塞 D-cache、LSU 顺序限制、前端队列和恢复等待仍然存在 |
| 阵列小，面积为何不只由 512 B 数据决定？ | 还有 tag、GPR、各级宽 payload、旁路 mux、预测/控制状态、复位及综合映射开销；同步数组不能自动按 SRAM 宏面积计算 |

历史参数实验与面积边界见 [结构、参数与选择理由](RV32_DESIGN_CHOICES.md)，取消 RR 前的低侵入
train 数值见 [远程版本说明](RV32_REMOTE_SNAPSHOT.md)。本次回归与综合记录独立保存，
历史 train 不代表新结构的成绩，见 [取消 RR 的实现记录](RV32_RR_REMOVAL_2026-09-15.md)。

## 11. 已识别的旧表述与更新规则

阅读 RTL 时应以当前信号赋值和实例为准。regfile 原有的“当前无转发”注释、预测器内
“查询旁路看到最新训练值”等旧表述均已修正；部分仿真接口仍保留较早的流水级名称。
当前实际连接为：前递位于 ID/EX 之前；BTB 训练直接更新数组，查询无训练旁路；EXU 内 AGU 送 LSU。

后续维护文字说明、参数表、接口契约及测量记录，不再要求更新架构图。
源码发生改变时记录版本及验证范围；没有重新测量的全核面积、频率或 IPC 继续标为历史数据。
