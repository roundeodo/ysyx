# RV64 与 RV32 当前实现的区别

核对日期：2026-09-26。比较主工程与 `ysyx-workbench-rv32-interview` 的实际 RTL，
RV32 配置采用 `rv32-balanced`。这是当前工作区的对照，不代表两个分支永远一致。

## 结论

两边都保持单发射和顺序提交。RV64 已增加顺序发射、独立功能单元乱序完成的后端，
与 RV32 的顺序完成路径存在结构差异，不能概括为“除 EXU 外只差位宽”。
要分别检查模块连接、展开后的参数、指令语义和分支中另外加入的功能。

| 部分 | 当前关系 |
| --- | --- |
| 主流水线 | 前端层次相近；RV64 在译码后增加 Issue 职责，复用 ID/EX 边界，发射后进入 8 项 scoreboard。各 FU 独立返回，队首顺序提交；没有独立重命名表、物理寄存器堆或动态选发 |
| 冒险与前递 | RV64 用 Issue 与 scoreboard 检查 RAW、资源和串行化；同名写按最近生产者前递，支持各 FU 当拍及已完成结果前递；旧 hazard controller 不再实例化 |
| 数据访存 | RV64 的 LSU 增加返回所需的 scoreboard 索引，访存可跨过已排除异常的较老纯运算，前一条访存仍必须提交后才释放上下文；数据访存路由、tag/data 阵列、D-cache AXI 和 uncached AXI 的既有对照未变；RV64 的 D-cache 与 miss 单元提前准备响应载荷，保持原握手、错误恢复与同拍交接 |
| 取指 | 取指缓冲、I-cache 数据阵列、缺失处理和 AXI 适配的参数化 RTL 相同；RV64 删除 IFU 中已知 taken 条件下的冗余选择，并按已有 miss 状态选择 I-cache 响应载荷，握手和周期不变 |
| 缓存与预测配置 | 都选择 I-cache 1024 B / 4 路 / 32 B / policy 13，D-cache 256 B / 2 路 / 16 B，BHT 16、BTB 16 项 / 2 路、RAS 4 项 |
| 实验逻辑 | RV32 源码还包含其他替换、gshare、bi-mode、TAGE 和目标压缩等实验分支；选定配置没有启用这些分支。RV64 保留较精简的选定方案 |
| 指令语义 | RV64 需要 OP-32/OP-IMM-32、W 结果符号扩展、LD/SD/LWU 等译码；本轮另加入 RV64M，不能靠统一放大位宽获得这些语义 |
| CSR 与中断 | 当前 RV32 已连接 CLINT 定时器中断、CSR 使能与中断控制器；当前 RV64 尚未接入这条中断路径 |
| FENCE.I 失败处理 | 当前 RV64 在 D-cache 清理失败后重试；RV32 转入保持的失败状态并提供失败输出。这是恢复策略差异 |
| 完成与提交 | RV64 用 scoreboard 替代活动路径中的 completion mux 与 WB 存储，复用 commit 的架构更新；RV32 保持原路径，恢复记录另有 `flush_inclusive` 字段 |

这里的“参数化 RTL 相同”指适配 `riscv32_` 前缀、排除注释和格式后代码一致，
不等于综合出的门级电路完全相同，也不是跨 ISA 的形式等价证明。
加入 scoreboard 前的逐文件清单见[历史对照证据](../../result/verification/exu-functional-units-20260926/rv32-core-comparison-final.json)。后端增量见[scoreboard 集成记录](../verification/SCOREBOARD_INTEGRATION_2026-09-26.md)及[等待优化](../verification/SCOREBOARD_WAITS_2026-09-26.md)，
旧清单不能证明当前所有文件仍相同。

## 位宽改变的实际影响

通用寄存器、操作数、结果、前递选择器和部分流水载荷随 XLEN 扩宽。
指令仍为 32 位；当前物理地址仍为 32 位；缓存容量按字节配置，不随 XLEN 自动翻倍。
总线每拍数据量、字节使能和拆分次数由各自接口宽度决定。
因此，“模块框架相同”不能直接推出面积只增加寄存器，也不能推出频率保持不变。
PC/BTB 地址宽度的取舍不在本轮修改范围内。

中断支持和 FENCE.I 失败策略需要各自的设计与回归，不能作为普通重命名顺带合入。
本轮执行单元的结构、时序规则与测试见[执行单元设计](../microarchitecture/EXECUTION_UNITS_DESIGN_RECORD.md)
及[验证记录](../verification/EXU_INTEGRATION_2026-09-26.md)。
