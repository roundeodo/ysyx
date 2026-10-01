# RISC-V 设计模块总览与代码整理清单

原目录检查：2026-09-05；旁路与等待优化迁移：2026-09-24；风格同步：2026-09-25；目录分层与执行单元：2026-09-26

范围：`npc/vsrc/riscv` 的处理器、系统、仿真与实验文件，另有两份 filelist。这里同时包含处理器 RTL、平台连接、仿真环境和实验。

2026-09-24 同步缓存配置并迁入已验证的旁路与等待优化，范围见[迁移记录](../verification/RV64_BYPASS_SYNC_2026-09-24.md)。

2026-09-25 对照 RV32 核对了 62 个 HDL 文件，统一条件/分支换行、事件名称和代码分组；
其中 33 个文件在工程名称适配后复用源实现。逐文件清单及验证见
[配置与风格同步记录](../verification/DCACHE_STYLE_SYNC_2026-09-25.md)。

新增 `riscv_icache_replacement`，说明见[I-cache 替换逻辑](../microarchitecture/ICACHE_REPLACEMENT_DESIGN.md)。

2026-09-27 程序测试统一到完整 SoC，宽度转换补齐多拍回填/写回；被动计时接口为
`sim/riscv_perf_dpi.svh`。见[当前测试约定](../verification/SOC_TESTING.md)。

本表覆盖当前文件与职责。此前逐文件检查及后续修复见 [实现记录](RTL_CLEANUP_RECORD.md)，
不代表已经逐项证明全部功能。
命名与格式修改的验证结果见 [验证记录](../verification/EXPERIMENT_LOG.md)。

与 RV32 当前工作区的逐项区别见[实现对照](RV64_RV32_CURRENT_COMPARISON.md)。

## 1. 目录与命名

原目录 `vsrc/riscv32` 改为 `vsrc/riscv`，原设计模块和 package 的 `riscv32_` 前缀统一为
`riscv_`。构建使用 `PROJECT=riscv`；当前为 RV64IM、Zicsr、Zifencei，整数宽度为 64 位。

`riscv_config_pkg` 原来就没有绑定 32 位，名称保持。独立仿真的 `top`、DPI 函数以及外部
平台规定的端口名属于已有接口。真正描述 32 位数据的实验名称保留位宽说明，例如
`riscv_alu32_for_sta`。NEMU、软件目标与历史记录中的 RV32 名称不属于这次设计前缀迁移。

当前 `core/` 的入口为 `riscv_core.sv`，其余文件按职责分层：

```text
core/
  riscv_core.sv       整核连接
  frontend/          取指、预测、I-cache
  decode/            译码、寄存器堆、操作数选择
  issue/             依赖与前递、scoreboard 在途指令与完成队列
  execute/           ID/EX、ALU、分支、乘法、除法、执行结果寄存器
  memory/            LSU、D-cache、数据侧 AXI
  writeback/         提交、CSR、PMU；保留旧完成选择与 WB 单元供历史测试
  control/           冒险、恢复、FENCE.I 与异常控制
```

`filelist/filelist.f` 用于仿真，包含仿真统计开关与模块；`filelist/filelist_sta.f` 用于综合
分析。被列入 filelist 只说明源码参与构建，不等于模块已经在顶层实例化。

## 2. 本次已经统一的内容

- 设计目录、模块名、package 名、对应文件名、测试顶层及其构建引用。
- 综合约束文件名、平台 BlackBox 名称、DPI 层次访问和当前文档链接。
- 寄存器、预测记录、替换索引等数组名称，以及取指恢复请求的位集合名称。
- 已过期的 RV32、单周期、无前递和 P0～P6 阶段说明。
- 按工作区现有格式器进行列对齐和换行，检查代码标记仅有预定重命名变化。
- 修正格式器将续行过度右移的问题，并在本目录的 [AGENTS.md](../../vsrc/riscv/AGENTS.md)
  中列明修改时必须阅读的规范与模块记录。

下图按实例化关系归纳主要层次，箭头表示“包含”，不表示数据流向。共享 package 和
仿真统计模块未画出；每个文件的职责见下方表格。

```mermaid
flowchart TD
    sim["top：独立仿真入口"] --> system["riscv_npc_system：处理器系统"]
    soc["riscv_npc_axi：SoC 入口"] --> system
    sim --> models["仿真地址路由、内存和串口"]
    soc --> converter["SoC AXI 位宽转换"]
    system --> reset["riscv_reset_controller：同步释放系统复位"]
    system --> core["riscv_core：处理器核"]
    system --> bus["I/D 读仲裁、地址路由和 CLINT"]
    core --> frontend["取指、预测与指令缓存"]
    core --> pipeline["译码、读寄存器、执行、访存与提交"]
    core --> memory["数据缓存与 uncached 访问"]
    core --> state["架构寄存器、CSR、异常与恢复控制"]
```

## 3. 全部文件的职责与关注点

### common：配置、地址和共享类型

| 文件 | 当前职责 | 可读性、维护性与后续关注点 |
| --- | --- | --- |
| [riscv_config_pkg](../../vsrc/riscv/common/riscv_config_pkg.sv) | 全核位宽、容量和构建配置 | 只保留当前使用的配置；已使用的 SCOREBOARD_ENTRY_COUNT 统一为 8，重命名/LSQ 候选参数仍不预置 |
| [riscv_addr_map_pkg](../../vsrc/riscv/common/riscv_addr_map_pkg.sv) | 物理地址区间、复位地址和地址范围判断 | 地址属于物理地址类型，避免与整数宽度混用 |
| [riscv_axi4_pkg](../../vsrc/riscv/common/riscv_axi4_pkg.sv) | core AXI 通道与方向结构体 | 保留 AXI 标准字段名，统一地址、数据和字节使能宽度 |
| [riscv_ysyx_soc_axi4_pkg](../../vsrc/riscv/common/riscv_ysyx_soc_axi4_pkg.sv) | 外部 ysyxSoC 的 AXI 类型 | 与 core AXI 类型分开，由转换模块连接 |
| [riscv_pkg](../../vsrc/riscv/common/riscv_pkg.sv) | ISA 编码、操作类型、流水级数据及事件定义 | 只保留当前接口类型；共用按字节合并函数，删除未使用的乱序占位类型 |

### core/frontend：预测、取指缓冲与指令缓存

| 文件 | 当前职责 | 可读性、维护性与后续关注点 |
| --- | --- | --- |
| [riscv_fetch_buffer](../../vsrc/riscv/core/frontend/riscv_fetch_buffer.sv) | 保存已返回指令并吸收译码反压 | 保持入队、出队、flush 与有效状态的关系清楚 |
| [riscv_branch_predictor](../../vsrc/riscv/core/frontend/riscv_branch_predictor.sv) | BHT、BTB、RAS 查询与训练 | 训练入口复用类型判断；查询、训练和返回栈的声明与计算分别组织 |
| [riscv_bht](../../vsrc/riscv/core/frontend/riscv_bht.sv) | PC 索引的二位方向计数器 | 查询组合读、解析后更新，状态由本模块独占 |
| [riscv_btb](../../vsrc/riscv/core/frontend/riscv_btb.sv) | 组相联目标与类型表 | 查询组合读、解析后更新，状态由本模块独占 |
| [riscv_ras](../../vsrc/riscv/core/frontend/riscv_ras.sv) | 解析后更新的返回地址栈 | 查询组合读、解析后更新，状态由本模块独占 |
| [riscv_pma](../../vsrc/riscv/core/frontend/riscv_pma.sv) | 判断地址的执行、读写和缓存属性 | 复用地址表；区分 PMA 与未来虚拟内存权限 |
| [riscv_icache_replacement](../../vsrc/riscv/core/frontend/riscv_icache_replacement.sv) | 保存分段访问 RRIP 状态及候选路快照 | 同拍命中前递；反压保持；不重复保存 tag 或有效位 |
| [riscv_icache](../../vsrc/riscv/core/frontend/riscv_icache.sv) | 指令缓存查找、命中、替换和失效协调 | 已删除不能启用的回填字选择与逐字可见状态；保留原缺失请求提前返回 |
| [riscv_icache_tag_array](../../vsrc/riscv/core/frontend/riscv_icache_tag_array.sv) | 保存地址标记和行有效状态，提供同步读口 | 状态与数据的复位行为不同，注释应明确写入和失效条件 |
| [riscv_icache_data_array](../../vsrc/riscv/core/frontend/riscv_icache_data_array.sv) | 指令数据阵列与同步读出 | 当前使用暂存寄存器和低电平锁存写阵列，不能笼统称为普通触发器 RAM |
| [riscv_icache_miss_unit](../../vsrc/riscv/core/frontend/riscv_icache_miss_unit.sv) | 跟踪一次缺失、回填进度、原请求响应和错误 | 保留输出、下一值、时序更新顺序；注释已区分原请求提前返回和后续查找阻塞 |
| [riscv_icache_axi](../../vsrc/riscv/core/frontend/riscv_icache_axi.sv) | 将指令回填转换成 AXI 读突发 | 独立说明请求接收、AR/R 握手及每拍的有效传输大小 |

### core 各子目录：指令流水线与架构状态

| 文件 | 当前职责 | 可读性、维护性与后续关注点 |
| --- | --- | --- |
| [riscv_core](../../vsrc/riscv/core/riscv_core.sv) | 连接取指、译码、执行、访存与提交 | 操作数选择与维护状态机已独立；接口声明与对应连接放近 |
| [riscv_operand_mux](../../vsrc/riscv/core/decode/riscv_operand_mux.sv) | 组合选择送入 ID/EX 的操作数 | 按语义选择立即数、PC 和 Issue 已前递的寄存器值 |
| [riscv_fence_i_ctrl](../../vsrc/riscv/core/control/riscv_fence_i_ctrl.sv) | FENCE.I的清理、重试与失效次序 | 清理失败时保持取指阻塞，撤下请求一拍后重试 |
| [riscv_ifu](../../vsrc/riscv/core/frontend/riscv_ifu.sv) | 发出预测与缓存请求，管理 tag、epoch 和返回指令 | 请求队列、单项在途预测、路径恢复分别组织；位集合与数组名称区分 |
| [riscv_idu](../../vsrc/riscv/core/decode/riscv_idu.sv) | 提取指令字段并生成译码操作 | 大 case 本身不等于不合理；按指令类别保持默认值、合法性和输出定义一致 |
| [riscv_decode_stage](../../vsrc/riscv/experiments/pipeline/riscv_decode_stage.sv) | 历史译码寄存级，不参与正式构建 | 简单 valid/ready 寄存级，无需强行改成枚举状态机 |
| [riscv_register_read_stage](../../vsrc/riscv/experiments/pipeline/riscv_register_read_stage.sv) | 历史读寄存器级，不参与正式构建 | 旁路说明与实际寄存器更新相邻 |
| [riscv_regfile](../../vsrc/riscv/core/decode/riscv_regfile.sv) | 保存 x1～x31，读取 x0 时返回零 | 已改为 gpr_array_q，并修正 RV32 与无前递旧注释 |
| [riscv_csr_file](../../vsrc/riscv/core/writeback/riscv_csr_file.sv) | CSR 访问、合法性、异常入口和返回时状态更新 | 多类 CSR 更新集中在一个时序块；若拆分须保持异常、返回和普通写入的优先级 |
| [riscv_pmu](../../vsrc/riscv/core/writeback/riscv_pmu.sv) | 软件可见的周期、退休计数及控制位 | 与仿真统计分开；保留按计数器分组的更新 |
| [riscv_issue_ctrl](../../vsrc/riscv/core/issue/riscv_issue_ctrl.sv) | 检查 RAW、选择最近生产者前递、控制顺序发射 | 同时检查 scoreboard 与尚在 ID/EX 的生产者，复用既有寄存边界 |
| [riscv_scoreboard](../../vsrc/riscv/core/issue/riscv_scoreboard.sv) | 按序分配、按标识接收四路完成、按序交给提交 | 紧凑元数据与最近写者标志；单访存/串行 CSR 副作用各存一份；分支保留较老运算 |
| [riscv_id_ex_reg](../../vsrc/riscv/core/execute/riscv_id_ex_reg.sv) | 保存进入 EX 的指令和操作数 | 有效位与数据寄存器分开，检查旁路标记及反压语义 |
| [riscv_hazard_ctrl](../../vsrc/riscv/core/control/riscv_hazard_ctrl.sv) | 旧顺序核的相关与推进控制，现仅供历史测试 | 活动核改用 Issue/scoreboard；旧形式结果不证明新后端 |
| [riscv_exu](../../vsrc/riscv/core/execute/riscv_exu.sv) | 按序向各 FU 发请求，生成 CSR 写值和 LSU 地址 | 请求接收即释放 ID/EX，乘除通过独立带标识结果口返回 |
| [riscv_alu](../../vsrc/riscv/core/execute/riscv_alu.sv) | RV64I 整数与 W 运算 | 共享加减/比较及左右移位电路，组合输出 |
| [riscv_branch_unit](../../vsrc/riscv/core/execute/riscv_branch_unit.sv) | 条件比较、JAL/JALR 目标和对齐判断 | 全宽地址与原语义保持一致；预测校验在结果级 |
| [riscv_multiplier](../../vsrc/riscv/core/execute/riscv_multiplier.sv) | MUL、MULH、MULHSU、MULHU、MULW | 三级部分积流水，反压保持，flush 取消 |
| [riscv_divider](../../vsrc/riscv/core/execute/riscv_divider.sv) | DIV/REM 及无符号和 W 变体 | 迭代除法，边界快速处理与前导零跳过 |
| [riscv_ex_result_reg](../../vsrc/riscv/core/execute/riscv_ex_result_reg.sv) | 保存执行结果并检查预测是否正确 | 保留输出、有效位下一值、寄存器更新的顺序 |
| [riscv_lsu](../../vsrc/riscv/core/memory/riscv_lsu.sv) | 访问大小、对齐、字节使能、读值扩展和完成响应 | 格式化函数与使用位置相近；已删除无调用的请求分类函数 |
| [riscv_completion_mux](../../vsrc/riscv/core/writeback/riscv_completion_mux.sv) | 旧完成选择器，保留用于历史单元测试 | 活动核使用四个独立 scoreboard 完成入口 |
| [riscv_wb_reg](../../vsrc/riscv/core/writeback/riscv_wb_reg.sv) | 旧单项 WB，保留用于历史单元测试 | 活动核的结果寄存与排序由 scoreboard 承担 |
| [riscv_commit](../../vsrc/riscv/core/writeback/riscv_commit.sv) | 消费 scoreboard 最老完成项，生成架构提交事件 | 更新 GPR/CSR 并处理异常，不能提交先完成的年轻项 |
| [riscv_trap_ctrl](../../vsrc/riscv/core/control/riscv_trap_ctrl.sv) | 根据提交记录生成异常或 mret 重定向 | 中断路径仍待接通，不能把存在 cause 字段当成已支持中断 |
| [riscv_redirect_mux](../../vsrc/riscv/core/control/riscv_redirect_mux.sv) | 当拍按年龄与优先级选择恢复来源 | 提交恢复优先，当前非分支纠错只清年轻项 |
| [riscv_frontend_redirect_register](../../vsrc/riscv/experiments/pipeline/riscv_frontend_redirect_register.sv) | 历史恢复寄存器，不参与正式构建 | 内部数组已加 _array；端口集合的后缀一致性留待独立接口整理 |

### core/memory：数据缓存与访存总线适配

| 文件 | 当前职责 | 可读性、维护性与后续关注点 |
| --- | --- | --- |
| [riscv_data_mem](../../vsrc/riscv/core/memory/riscv_data_mem.sv) | 按地址属性选择缓存或 uncached 路径 | 保持选择直到响应结束，避免用后续请求地址改写事务归属 |
| [riscv_dcache](../../vsrc/riscv/core/memory/riscv_dcache.sv) | 数据缓存查找、替换和脏行维护 | 已统一替换索引数组名称；按查找、旁路、维护、缺失接口整理声明 |
| [riscv_dcache_tag_array](../../vsrc/riscv/core/memory/riscv_dcache_tag_array.sv) | 保存标记、有效位和脏位 | 元数据写入与数据写入分工清楚，同周期读写规则需明确 |
| [riscv_dcache_data_array](../../vsrc/riscv/core/memory/riscv_dcache_data_array.sv) | 同步读取和按字节更新数据阵列 | 保持简单阵列职责，不引入替换或总线状态 |
| [riscv_dcache_miss_unit](../../vsrc/riscv/core/memory/riscv_dcache_miss_unit.sv) | 处理脏行写回、回填时合并 store 和返回原请求结果 | 写回与回填并行；写回失败后用唯一整行缓冲恢复旧脏行再报错 |
| [riscv_dcache_axi](../../vsrc/riscv/core/memory/riscv_dcache_axi.sv) | D-cache 行读写的 AXI 转换 | 读写状态独立，上游普通缺失已使用并行能力；空闲时首拍 AW/W 可直通 |
| [riscv_uncached_axi](../../vsrc/riscv/core/memory/riscv_uncached_axi.sv) | 将单次普通访存或 MMIO 转成 AXI 请求 | 地址、数据握手历史按实际事件命名，保持协议错误处理 |

### system：系统连接与平台边界

| 文件 | 当前职责 | 可读性、维护性与后续关注点 |
| --- | --- | --- |
| [riscv_reset_controller](../../vsrc/riscv/system/riscv_reset_controller.sv) | 异步进入复位，两级同步后在下降沿统一释放 | 使用未门控时钟；系统内各状态模块共享释放结果 |
| [riscv_core_reset_boundary](../../vsrc/riscv/system/riscv_core_reset_boundary.sv) | 包含实际复位控制器的纯核 STA 边界 | 与实际系统复用同一复位模块；不包含 CLINT 或 SoC |
| [riscv_npc_system](../../vsrc/riscv/system/riscv_npc_system.sv) | 合并 I/D AXI，连接 CLINT 并转发外部地址 | 主要为实例化和连接，可作为顶层组织的参考 |
| [riscv_axi4_arbiter](../../vsrc/riscv/system/riscv_axi4_arbiter.sv) | 仲裁指令和数据读事务，传递数据写通道 | 请求选择、事务锁和下一优先级分别有明确状态 |
| [riscv_axi4_router](../../vsrc/riscv/system/riscv_axi4_router.sv) | 按地址选择目标并保持事务归属 | select_vector 与 select_index 命名较清楚；后续统一循环索引和辅助函数名称 |
| [riscv_axi4_soc_width_converter](../../vsrc/riscv/system/riscv_axi4_soc_width_converter.sv) | core 与 ysyxSoC 数据宽度转换 | 读写状态分别组织；读请求与反向应答分开计算，保持各自组合依赖 |
| [riscv_npc_axi](../../vsrc/riscv/system/riscv_npc_axi.sv) | 将内部接口展开成 ysyxSoC 所需端口 | 平台端口名和 DPI 函数名是外部接口，不机械添加内部后缀 |
| [riscv_axi4_clint](../../vsrc/riscv/system/peripheral/riscv_axi4_clint.sv) | 计时及相关寄存器的 AXI 访问 | 区分计时、读事务、写事务；寄存器可访问不等于 core 已接受中断 |

### sim：仿真环境与统计

| 文件 | 当前职责 | 可读性、维护性与后续关注点 |
| --- | --- | --- |
| [riscv_sim_statistics_pkg](../../vsrc/riscv/sim/riscv_sim_statistics_pkg.sv) | 仿真监视器共用比例与延迟计算 | 不进入可综合filelist；不保存计数状态 |
| [top](../../vsrc/riscv/sim/top.sv) | 连接独立仿真环境并导出 DPI 调试接口 | 层次寄存器引用已同步；与SoC边界共用DPI导出；异常next PC改用同拍提交重定向 |
| [riscv_axi4_sim_mem](../../vsrc/riscv/sim/riscv_axi4_sim_mem.sv) | 仿真内存、突发访问和可控延迟 | 读写状态分开；作为行为模型保留仿真专用操作 |
| [riscv_axi4_uart_sim](../../vsrc/riscv/sim/riscv_axi4_uart_sim.sv) | 仿真串口访问与字符输出 | 按读写事务组织，打印操作与协议响应分开 |
| [riscv_sim_perf_monitor](../../vsrc/riscv/sim/riscv_sim_perf_monitor.sv) | 记录整核事件并报告性能估算 | 原始计数、控制流分类与候选估算分别组织；比例与延迟函数共用 |
| [riscv_sim_icache_monitor](../../vsrc/riscv/sim/riscv_sim_icache_monitor.sv) | 统计 I-cache 请求、命中、缺失和延迟 | 事件与计数器名称对应；报告输出与计时状态分组，共用比例和延迟函数 |
| [riscv_sim_dcache_monitor](../../vsrc/riscv/sim/riscv_sim_dcache_monitor.sv) | 统计 D-cache 访问、缺失、写回和等待 | 原始事件与推算值分别标记；比例与延迟计算使用共用仿真包 |

### experiments：独立教学与综合实验

| 文件 | 当前职责 | 可读性、维护性与后续关注点 |
| --- | --- | --- |
| [riscv_alu32_for_sta](../../vsrc/riscv/experiments/riscv_alu32_for_sta.sv) | 独立的 32 位 ALU 综合实验 | 名称保留真实数据宽度 32，避免误认作当前 RV64 EXU；不在正式 filelist 中 |
| [shl4_for_sta](../../vsrc/riscv/experiments/shl4_for_sta.sv) | 4 位可变移位综合实验 | 独立小实验，后续可把 in/out 改为说明含义的端口名 |
| [bcd7seg](../../vsrc/riscv/experiments/bcd7seg.v) | 七段数码管译码实验 | 不在正式 filelist 中；若重新使用，再按实验输入范围整理命名与端口后缀 |

本轮复位与电气修复见 [验证记录](../verification/RESET_ELECTRICAL_FIX_2026-09-25.md)。

## 4. 后续修改的依据

1. **保持功能与验证收敛**：已修复缓存反压、脏数据恢复和提交PC采样问题，并更新形式
   验证接口与性质。本轮清理、回归和面积/时序比较见 [实现记录](RTL_CLEANUP_RECORD.md)。
2. **保持局部结构清楚**：core 的操作数选择和维护控制已独立，预测器、缓存、宽度转换器
   与统计模块已按功能整理。后续新增逻辑继续把声明、计算与状态更新放在负责它的功能附近。
3. **独立处理接口变化**：数组端口后缀、模块拆分与公共类型拆分，
   每次形成小范围改动并运行受影响测试，不在机械重命名中顺便改变行为。
4. **最后根据需要优化结构**：状态数量、寄存器边界和旁路路径的改变会影响功能与时序，
   不能当成纯格式修改；需要对应的回归和时序依据。

代码行数只用于定位阅读成本，不作为必须拆分的阈值。大译码 case 可以保持集中；纯组合
选择器与简单流水寄存级不需要人为增加状态机。显式锁存阵列也不能按普通组合逻辑的规则
补默认赋值来消除其存储行为。

编码约定见 [命名与代码组织规范](../development/NAMING_GUIDE.md)，每次工作的验证范围见
[开发流程](../development/DEVELOPMENT_PROCESS.md)。

`riscv_redirect_arbiter` 与 `riscv_axi4_error_target` 因无实例和测试使用已删除；旧源码保留在
[修改前快照](../../result/verification/rtl-cleanup-20260905/before/vsrc/riscv)。共享DPI头文件
[riscv_sim_debug.svh](../../vsrc/riscv/sim/riscv_sim_debug.svh)不计入上述HDL模块与package数量。
