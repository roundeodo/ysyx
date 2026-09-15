# NPC 文档中心

> 本工作树恢复自 `bb03677`，并已新增本地定时中断，用于 RV32 简历核对与面试准备。请先读
> [RV32 架构与模块说明](interview/RV32_ARCHITECTURE_ATLAS.md) 和
> [RV32 简历核对与面试准备](interview/RV32_RESUME_AUDIT.md)。其余设计记录保留历史内容，
> 其中的阶段性默认参数、待办和 PPA 不能不加版本区分地当作本分支现状。

本目录是 NPC 项目的唯一文档入口。RTL 目录只保存源码和紧邻实现位置的局部注释；跨模块
契约、架构决策、开发规范、实验结果和学习记录统一放在这里。

除标准名称、协议字段、代码标识、命令、路径和 URL 外，正文统一使用中文维护。

## 目录结构

| 目录 | 内容 | 主要读者 |
| --- | --- | --- |
| [`interview/`](interview/) | 当前 RV32 架构、逐模块说明、参数取舍及简历核对 | 面试准备与当前版本维护者 |
| [`architecture/`](architecture/) | 产品场景、AI 负载模型、体系结构路线和冻结决策 | 全体开发者 |
| [`development/`](development/) | 命名、参数化、模块化、评审和设计记录模板 | RTL 与验证开发者 |
| [`interconnect/`](interconnect/) | AXI、APB、片上互连和协议迁移记录 | SoC 与存储子系统开发者 |
| [`microarchitecture/`](microarchitecture/) | I-cache 等具体模块的设计记录 | 模块所有者与评审者 |
| [`verification/`](verification/) | 可复现实验、性能结果和回归记录 | 验证与性能分析人员 |
| [`learning/`](learning/) | 从设计和实验中提炼的学习记录 | 当前及后续学习者 |

历史上已经被新决策替代的文档放入对应目录的 `archive/`。归档文件只能用于追溯，不能作为
当前实现依据。

## 权威文档

- [RV32 架构与模块说明](interview/RV32_ARCHITECTURE_ATLAS.md)：实际寄存边界、模块职责、数据流、当前参数和实现边界。
- [取消独立 RR（2026-09-15）](interview/RV32_RR_REMOVAL_2026-09-15.md)：译码、GPR 读取与前递直连 ID/EX，功能回归及新面积、频率和 MicroBench 测量。
- [取指预测器模块设计](microarchitecture/FETCH_PREDICTOR_DESIGN_RECORD.md)：BHT、BTB、RAS 的独立状态、统一查询控制和保持原有拍数的接口契约。
- [RV32 定时中断](microarchitecture/TIMER_INTERRUPT_DESIGN_RECORD.md)：CLINT、流水线精确受理及验证范围。

- [完整AXI4互连架构](interconnect/AXI4_ARCHITECTURE.md)：当前主链边界、事务能力和后续扩展规则。
- [I-cache设计空间探索](verification/CACHE_DESIGN_SPACE_EXPLORATION.md)：NEMU itrace、3C模型、AMAT/TMT和cachesim命令。
- [顺序流水线设计记录](microarchitecture/PIPELINE_DESIGN_RECORD.md)：流水级payload、冒险控制、flush和精确提交契约。

- 最终产品和架构路线：[`architecture/ARCHITECTURE_PLAN.md`](architecture/ARCHITECTURE_PLAN.md)
- P2配置和宽度解耦：[`architecture/P2_CONFIGURATION_PLAN.md`](architecture/P2_CONFIGURATION_PLAN.md)
- P2宽度依赖审计：[`architecture/P2_WIDTH_AUDIT.md`](architecture/P2_WIDTH_AUDIT.md)
- P3 RV64顺序处理器实施计划：[`architecture/P3_RV64_SEQUENTIAL_PLAN.md`](architecture/P3_RV64_SEQUENTIAL_PLAN.md)
- AI 工作负载依据：[`architecture/AI_WORKLOAD_MODEL.md`](architecture/AI_WORKLOAD_MODEL.md)
- 固定开发流程：[`development/DEVELOPMENT_PROCESS.md`](development/DEVELOPMENT_PROCESS.md)
- 命名和源码组织：[`development/NAMING_GUIDE.md`](development/NAMING_GUIDE.md)
- 模块设计模板：[`development/MODULE_DESIGN_RECORD_TEMPLATE.md`](development/MODULE_DESIGN_RECORD_TEMPLATE.md)

当源码、TODO、旧文档与上述权威文档冲突时，应先停止扩大改动，更新决策记录并明确迁移
方案。不能同时维护两套互相冲突的架构定义。

## 文档更新规则

1. 产品目标或模块边界改变时，先更新架构计划，再修改 RTL。
2. 新模块开工前创建设计记录；没有接口契约、正确性不变量和验证计划，不进入实现阶段。
3. 参数、端口或协议发生变化时，同一次修改必须更新父模块、断言、测试和相关文档。
4. 性能结论必须附带 Git commit、配置、命令和原始计数器数据。
5. 学习记录区分“已经由证据支持的结论”和“仍需验证的假设”。

- [RV32 D-cache 时序优化（2026-09-06）](verification/RV32_TIMING_FIX_2026-09-06.md)：820 MHz setup 通过，复位 removal 待修复。

- [RV32 复位与重定向修复（2026-09-06）](verification/RV32_RESET_REDIRECT_FIX_2026-09-06.md)：含复位控制器/缓冲树的纯核边界通过 820 MHz 综合后 max/min 时序检查。

- [历史 RV32 MicroBench test 基线（2026-09-06）](verification/RV32_MICROBENCH_TEST_2026-09-06.md)：10 项通过，旧 PMU 窗口 IPC 0.261728；不能作为取消 RR 后的性能。

- [RV32 面积与 train IPC 优化实验（本轮已完成）](verification/RV32_HARDWARE_OPTIMIZATION_2026-09-06.md)

- [MicroBench 计时与比较规则](verification/MICROBENCH_TIMING_RULES.md)：区分宿主耗时、计分时间、PMU 窗口和校准后的 CPU 时间。

- [RV32 面试准备：结构、参数与选择理由](interview/RV32_DESIGN_CHOICES.md)：当前结构、准确参数、选择依据、历史 train 取舍案例和简历表述边界。
