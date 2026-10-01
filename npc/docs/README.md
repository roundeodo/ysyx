# NPC 开发文档

本项目先完成 RV64 顺序核，再实现单发射乱序和超标量执行。边缘 AI 推理是长期应用方向，
具体模型与加速器需求在后续阶段确定。

## 如何运行程序

程序仿真统一使用完整 ysyxSoC，Flash 启动并在 SDRAM 执行。CPU 频率、设备延迟和 CLINT
使用同一配置。正式性能测试在 `npc` 中执行 `make perf`；短测试为
`make perf PERF_SCALE=test`。配置、统计口径和复现方式见 [SoC 测试说明](verification/SOC_TESTING.md)。
旧 standalone 成绩保留为历史记录，不与校准后的 SoC 成绩混用。

## 接下来怎么做

当前保留单发射与顺序发射，新增 scoreboard 支持不同功能单元乱序完成、顺序提交。
Issue 复用 ID/EX 寄存边界。同名写分别保存在结果队列中，由最近写者选择前递来源；
访存可跨过已排除异常的纯运算，访存之间保持顺序。没有物理寄存器堆或乱序挑选发射。
本轮减少等待的实现与验证状态见[第二轮验证](verification/SCOREBOARD_WAITS_2026-09-26.md)，
初版测量保留在[集成验证](verification/SCOREBOARD_INTEGRATION_2026-09-26.md)。
机器态中断、代表性软件测量和队列容量选优仍是后续事项，AI 需求不阻塞当前工作。

1. 阅读 [架构与开发路线](architecture/ARCHITECTURE_PLAN.md)，确认当前范围与阶段完成条件。
2. 修改模块前，阅读下方对应设计记录，写清本次要改变的行为和验证方法。
3. 按 [开发流程](development/DEVELOPMENT_PROCESS.md) 实现与检查，将实际结果追加到
   [验证记录](verification/EXPERIMENT_LOG.md)。

## 当前文档

| 需要了解什么 | 阅读哪份文档 |
| --- | --- |
| 项目目标、已有能力、阶段安排 | [架构与开发路线](architecture/ARCHITECTURE_PLAN.md) |
| 设计目录、全部模块与代码整理清单 | [设计模块总览](architecture/RTL_MODULE_MAP.md) |
| 当前 RV64 与 RV32 哪些相同、哪些不同 | [实现对照](architecture/RV64_RV32_CURRENT_COMPARISON.md) |
| 本轮修复、清理与实际验证结果 | [RTL 修复与清理](architecture/RTL_CLEANUP_RECORD.md) |
| 修复前的设计错误、旁路与可维护性检查 | [RTL 设计检查](architecture/RTL_DESIGN_REVIEW.md) |
| AI 方向哪些已讨论、哪些以后再定 | [AI 应用研究方向](architecture/AI_WORKLOAD_MODEL.md) |
| 当前流水线、相关、提交和恢复 | [流水线设计](microarchitecture/PIPELINE_DESIGN_RECORD.md) |
| 本轮 RV64M 接入、目录整理和测试结果 | [执行单元验证](verification/EXU_INTEGRATION_2026-09-26.md) |
| Issue、在途指令、乱序完成与顺序提交 | [Scoreboard 设计](microarchitecture/SCOREBOARD_DESIGN_RECORD.md) |
| 本轮并发、恢复、性能和时序结果 | [Scoreboard 验证](verification/SCOREBOARD_INTEGRATION_2026-09-26.md) |
| ALU、分支、乘法和除法的接口及结构 | [整数执行单元](microarchitecture/EXECUTION_UNITS_DESIGN_RECORD.md) |
| 指令缓存查找、回填和失效 | [I-cache 设计](microarchitecture/ICACHE_DESIGN_RECORD.md) |
| 数据缓存、写回和 uncached 路径 | [D-cache 设计](microarchitecture/DCACHE_DESIGN_RECORD.md) |
| 方向、目标和返回地址预测 | [分支预测设计](microarchitecture/BRANCH_PREDICTION_DESIGN_RECORD.md) |
| AXI 连接、仲裁、宽度转换和错误响应 | [AXI4 互连](interconnect/AXI4_ARCHITECTURE.md) |
| 从 RV32 实验同步的前端配置及验证 | [前端配置同步](verification/FRONTEND_CONFIGURATION_SYNC_2026-09-24.md) |
| RV64 比 RV32 多出的面积及可优化部分 | [面积差额审计](verification/RV64_RV32_AREA_AUDIT_2026-09-25.md) |
| 如何比较缓存配置 | [缓存配置比较方法](verification/CACHE_DESIGN_SPACE_EXPLORATION.md) |
| 测试命令、已有证据和待验证事项 | [验证记录](verification/EXPERIMENT_LOG.md) |
| 如何开展一次修改、如何写清文档 | [开发流程](development/DEVELOPMENT_PROCESS.md) |
| 如何命名和组织 RTL | [命名与代码组织](development/NAMING_GUIDE.md) |
| 如何记录新模块 | [模块设计记录模板](development/MODULE_DESIGN_RECORD_TEMPLATE.md) |

## 文档各自负责什么

- `architecture/`：项目范围、开发阶段和未来方向。
- `microarchitecture/`：模块的结构、接口、工作过程及限制。
- `interconnect/`：总线连接与事务处理规则。
- `verification/`：测试方法、命令、配置和测量结果。
- `development/`：实现、命名、评审和写作要求。
- `learning/`：有上下文和日期的学习记录。

当前路线以架构计划为准；模块行为以对应设计记录说明，若与 RTL 不符，应记录差异并修正。
“已有 RTL”“曾通过某项测试”和“当前已验证”是不同状态。更新日期也不等于重新完成验证。

## 历史文档

- [RV32 架构计划快照](architecture/archive/RV32_ARCHITECTURE_PLAN_2026-07-30.md)
- [P2 配置迁移计划](architecture/P2_CONFIGURATION_PLAN.md)
- [P2 宽度审计](architecture/P2_WIDTH_AUDIT.md)
- [学习日志](learning/LEARNING_JOURNAL.md)

旧计划和历史记录用于追溯，不再约束当前阶段。保留原始结果及其配置，不把历史参数或
阶段编号当成现在的待办。
其中的旧源码路径按记录时的名称保留；当前路径对应关系见 [设计模块总览](architecture/RTL_MODULE_MAP.md)。
