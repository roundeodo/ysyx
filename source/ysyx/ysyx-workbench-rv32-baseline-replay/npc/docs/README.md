# NPC 文档中心

本分支用于 RV32 面试：先读[固定配置与构建](interview/RV32_REMOTE_SNAPSHOT.md)，
研究过程从[前端研究索引](learning/FRONTEND_RESEARCH_INDEX.md)进入。当前配置为
`rv32-balanced`；RV64、乱序和 AI 扩展路线文档不代表此分支已经实现的硬件。

当前设计从[模块说明目录](microarchitecture/README.md)进入；前端、后端、访存和总线分别维护电路与源码顺序。

每次开始 RTL 设计、修改或评审，先读[开发流程](development/DEVELOPMENT_PROCESS.md)和
[编码规范](development/NAMING_GUIDE.md)，执行其中的寄存器、等待与旁路检查。

> 本工作树恢复自 `bb03677`，并已新增本地定时中断，用于 RV32 简历核对与面试准备。请先读
> [RV32 架构与模块说明](interview/RV32_ARCHITECTURE_ATLAS.md) 和
> [RV32 简历核对与面试准备](interview/RV32_RESUME_AUDIT.md)。历史实验和归档记录中的
> 默认参数、待办及 PPA 需要按对应版本理解。

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
- [取指预测器模块设计](microarchitecture/FETCH_PREDICTOR_DESIGN_RECORD.md)：BHT、BTB、RAS 的独立状态、单级查询和训练时序。
- [I-cache 模块说明](microarchitecture/ICACHE_DESIGN_RECORD.md)：当前同步查询、阻塞回填与失效结构。
- [I-cache 结构与替换选型](verification/ICACHE_SELECTION_2026-09-21.md)：当前均衡预设、简单对照、PPA、退化与复现入口。
- [前端研究学习记录](learning/FRONTEND_RESEARCH_NOTES.md)：论文与项目、实际借鉴、模型到 RTL 的设计依据、负结果及与后续分支研究的边界。
- [分支预测研究学习记录](learning/BRANCH_RESEARCH_NOTES.md)：经典与近期论文、作者实现、边缘 AI 软件代理及小核改造边界。
- [分支预测探索与测量](verification/BRANCH_EXPLORATION_2026-09-22.md)：冻结基线、模型筛选、RTL 对照、PPA 与保留集验证。
- [分支目标存储探索](verification/BRANCH_TARGET_EXPLORATION_2026-09-23.md)：BTB-X启发的目标编码、完整目标对照、面积/时序及跨地址区间退化。
- [RV32 定时中断](microarchitecture/TIMER_INTERRUPT_DESIGN_RECORD.md)：CLINT、流水线精确受理及验证范围。

- [完整 AXI4 互连架构](interconnect/AXI4_ARCHITECTURE.md)：当前数据路径、事务归属和系统边界。
- [I-cache设计空间探索](verification/CACHE_DESIGN_SPACE_EXPLORATION.md)：NEMU itrace、3C模型、AMAT/TMT和cachesim命令。
- [顺序流水线说明](microarchitecture/PIPELINE_DESIGN_RECORD.md)：操作数准备、执行、前递、提交和 FENCE.I 控制。
- [D-cache 说明](microarchitecture/DCACHE_DESIGN_RECORD.md)：同步查询、store 旁路、写回/回填和 clean。
- [完整目录整理验证](verification/RV32_FULL_DIRECTORY_REVIEW_2026-09-19.md)：全部 67 个文件的检查范围、补充修改与回归。
- [整理后的面积、时序与性能复测](verification/RV32_READABILITY_PPA_2026-09-19.md)：同条件比较、综合编译修复和 microbench test 结果。
- [逻辑与可读性复查及优化取舍（2026-09-21）](verification/RV32_LOGIC_STYLE_AUDIT_2026-09-21.md)：剩余等待、代码冗余、触发频率与处理优先级。
- [FENCE.I 与写回错误修复（2026-09-21）](verification/RV32_CACHE_RECOVERY_2026-09-21.md)：预测恢复、维护失败停机、脏行恢复及定向测试/PPA。
- [源码整理与缓存交接实测（2026-09-21）](verification/RV32_REFINEMENT_2026-09-21.md)：候选实现、同条件测量与设备延迟模型限制。
- [前次后端与系统整理](verification/RV32_READABILITY_2026-09-16.md)：模块提取与代码重排的原始记录。

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
6. 模块说明只维护当前原理、结构、工作过程与关键取舍；参数表、实验结果和历史过程
   各有唯一维护位置，通过链接引用。更新已有说明，避免每次修改都再增加一份重复说明。

- [RV32 D-cache 时序优化（2026-09-06）](verification/RV32_TIMING_FIX_2026-09-06.md)：820 MHz setup 通过，复位 removal 待修复。

- [RV32 复位与重定向修复（2026-09-06）](verification/RV32_RESET_REDIRECT_FIX_2026-09-06.md)：含复位控制器/缓冲树的纯核边界通过 820 MHz 综合后 max/min 时序检查。

- [历史 RV32 MicroBench test 基线（2026-09-06）](verification/RV32_MICROBENCH_TEST_2026-09-06.md)：10 项通过，旧 PMU 窗口 IPC 0.261728；不能作为取消 RR 后的性能。

- [RV32 面积与 train IPC 优化实验（本轮已完成）](verification/RV32_HARDWARE_OPTIMIZATION_2026-09-06.md)

- [MicroBench 计时与比较规则](verification/MICROBENCH_TIMING_RULES.md)：区分宿主耗时、计分时间、PMU 窗口和校准后的 CPU 时间。

- [RV32 面试准备：结构、参数与选择理由](interview/RV32_DESIGN_CHOICES.md)：当前结构、准确参数、选择依据、历史 train 取舍案例和简历表述边界。
