# 微架构说明

当前 RV32 前端从[数据流与源码顺序](FRONTEND_REWRITE_DESIGN_RECORD.md)开始阅读。
模块说明用于快速理解当前电路；实验过程与测量结果在 `verification/` 中维护。

## 源码目录

`vsrc/riscv32/core` 按指令处理顺序组织，顶层只保留 `riscv32_core.sv`：

| 子目录 | 主要内容 |
| --- | --- |
| `frontend/` | IFU、预测器、I-cache、fetch buffer |
| `decode/` | IDU、GPR、操作数准备与前递选择 |
| `execute/` | ID/EX 接收寄存器、EXU、执行结果寄存器 |
| `memory/` | LSU、D-cache、uncached 与数据存储路由 |
| `writeback/` | 完成选择、WB 寄存器、提交、CSR 与 PMU |
| `control/` | 冒险、重定向、中断、异常与 FENCE.I 维护 |

目录表示功能归属，不等于一目录一拍；实际寄存边界见[流水线说明](PIPELINE_DESIGN_RECORD.md)。
`common/` 放共享类型，`system/` 放系统连接，`sim/` 放仿真模型与监视器。
当前仿真和综合清单只包含对应构建所需的源码；历史实现放入 `experiments/`，不混入当前模块目录。

## 不属于当前 CPU 的模块

以下四个模块没有当前实例，已移出仿真/综合清单；源码保留供追溯。

| 文件（省略 `riscv32_` 前缀） | 位置与用途 |
| --- | --- |
| `decode_stage.sv` | `experiments/pipeline/`：旧独立译码寄存级 |
| `register_read_stage.sv` | `experiments/pipeline/`：旧独立读寄存器级 |
| `redirect_arbiter.sv` | `experiments/pipeline/`：旧组合重定向仲裁 |
| `axi4_error_target.sv` | `experiments/interconnect/`：未接入的独立 AXI 错误响应目标 |

当前 `id_ex_reg`、`ex_result_reg`、`wb_reg` 保存指令/结果；`redirect_mux` 组合选择恢复来源，
没有恢复寄存级。不能把这些模块与旧 decode/RR 寄存级混淆。
仿真监视器仍由仿真宏启用，复位测量封装仍是综合顶层，均有明确用途。
未实例化源码原本就不生成硬件，迁移这些文件不会改变面积、流水级数或 IPC。

## 为什么保留这些模块边界

| 边界 | 保留理由 |
| --- | --- |
| `branch_predictor` 与 `bht` / `btb` / `ras` | 父模块负责查询握手和预测选择；三个子模块分别拥有计数器、目标表和返回栈，没有额外的查询流水级 |
| cache 的 tag/data 阵列、miss 单元、AXI 接口 | 分别管理存储端口、缺失处理和总线事务，等待与完成条件各自明确 |
| `lsu` 与 `data_mem` | 前者保存指令上下文、处理对齐和数据格式；后者负责 PMA 路由及 cache/uncached 访问 |
| `hazard_ctrl` 与 `operand_mux` | 前者集中相关比较与允许条件，后者集中数据选择和前递优先级，均为组合逻辑 |
| `completion_mux`、`wb_reg`、`commit` | 分别处理 EX/LSU 结果选择、反压保存和架构副作用；只有 `wb_reg` 增加寄存边界 |
| `interrupt_ctrl`、`trap_ctrl`、`fence_i_ctrl` | 分别拥有中断受理/恢复 PC、异常入口选择和 cache 维护顺序，职责不同 |
| `axi4_arbiter`、`axi4_router`、SoC 位宽转换 | 分别合并 I/D 请求、选择地址目标和适配总线数据宽度 |
| `core`、`npc_system`、复位测量顶层 | 分别定义整核、系统接口和综合测量范围，负责对应层次的装配 |

这些模块各有明确职责，因此保留现有边界。短模块应集中一套清楚的协议或选择规则。
名称采用通用术语，完整命名原则见[编码规范](../development/NAMING_GUIDE.md)。

## 当前前端

- [取指预测器](FETCH_PREDICTOR_DESIGN_RECORD.md)：BHT、BTB、RAS、单级查询与训练时序。
- [I-cache](ICACHE_DESIGN_RECORD.md)：同步查询、阻塞回填、AXI、错误与失效。
- IFU 与 fetch buffer 的状态和取舍见[前端总览](FRONTEND_REWRITE_DESIGN_RECORD.md)。

## 后端与系统

- [D-cache](DCACHE_DESIGN_RECORD.md)：写回/写分配、PMA 路由与共享访存。
- [流水线](PIPELINE_DESIGN_RECORD.md)：译码/操作数准备、执行、提交、冒险与 FENCE.I。
- [定时中断](TIMER_INTERRUPT_DESIGN_RECORD.md)：CLINT、CSR 与精确受理。
- [总线连接](../interconnect/AXI4_ARCHITECTURE.md)：仲裁、地址路由、错误目标与 SoC 适配。

整核参数见[RV32 架构说明](../interview/RV32_ARCHITECTURE_ATLAS.md)。
[分支预测实验](BRANCH_PREDICTION_DESIGN_RECORD.md)保留退休 trace 与 BranchSim 的实验过程；
`archive/` 只用于追溯，不作为当前设计依据。

## 维护方式

先用[精简模板](../development/MODULE_DESIGN_RECORD_TEMPLATE.md)确定结构，再按
[编码规范](../development/NAMING_GUIDE.md)实现；验证流程见[开发流程](../development/DEVELOPMENT_PROCESS.md)。
每个设计事实只在其所属说明中维护，其他文档链接引用。结构变化时直接更新当前说明，
旧方案需要追溯时归档；实验日志保留历史数据，不把过程记录不断追加到模块说明末尾。
